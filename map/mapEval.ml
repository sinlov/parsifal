open MapLang

(* Value and environment handling *)

module StringSet = Set.Make (String);;

type function_sort =
  | NativeFun of (value list -> value)
  | NativeFunWithEnv of (environment -> value list -> value)
  | InterpretedFun of (environment * string list * expression list)

and value =
  | V_Unit
  | V_Bool of bool
  | V_Int of int
  | V_String of string
  | V_Function of function_sort

  | V_List of value list
  | V_Set of StringSet.t
  | V_Dict of (string, value) Hashtbl.t
  | V_ValueDict of (value, value) Hashtbl.t
  | V_Stream of string * char Stream.t
  | V_OutChannel of string * out_channel
  | V_Lazy of value lazy_t

  | V_TlsRecord of Tls.record
  | V_Asn1 of Asn1.asn1_object
  | V_DN of X509.dn
  | V_Certificate of X509.certificate

and environment = (string, value) Hashtbl.t list

let global_env : (string, value) Hashtbl.t = Hashtbl.create 100

let add_module name dict = Hashtbl.replace global_env name (V_Dict dict)


let certificate_field_access : (string, X509.certificate -> value) Hashtbl.t = Hashtbl.create 40
let tls_field_access : (string, Tls.record -> value) Hashtbl.t = Hashtbl.create 40
let dn_field_access : (string, X509.dn -> value) Hashtbl.t = Hashtbl.create 40
let asn1_field_access : (string, Asn1.asn1_object -> value) Hashtbl.t = Hashtbl.create 40


exception NotImplemented
exception WrongNumberOfArguments
exception ContentError of string
exception ReturnValue of value
exception Continue
exception Break

(* TODO: Make asn1_display_options from config? *)
let opts = { Asn1.type_repr = Asn1.PrettyType; Asn1.data_repr = Asn1.PrettyData;
	     Asn1.resolver = Some X509.name_directory; Asn1.indent_output = true };;

let eval_as_string = function
  | V_Bool b -> string_of_bool b
  | V_Int i -> string_of_int i
  | V_String s -> s

  | V_List _ | V_Set _ | V_Dict _ | V_ValueDict _
  | V_TlsRecord _ | V_Asn1 _ | V_DN _ | V_Certificate _
  | V_Unit | V_Function _ | V_Stream _ | V_OutChannel _
  | V_Lazy _ ->
    raise (ContentError "String expected")

let rec eval_as_string_rec = function
  | V_Bool b -> string_of_bool b
  | V_Int i -> string_of_int i
  | V_String s -> s

  | V_List l ->
    "[" ^ (String.concat ", " (List.map eval_as_string_rec l)) ^ "]"
  | V_Set s ->
    "{" ^ (String.concat ", " (StringSet.elements s)) ^ "}"
  | V_Dict d ->
    let hash_aux k v accu =
      (k ^ " -> " ^ (eval_as_string_rec v))::accu
    in
    "{" ^ (String.concat ", " (Hashtbl.fold hash_aux d [])) ^ "}"
  | V_ValueDict d ->
    let hash_aux k v accu =
      ((eval_as_string_rec k) ^ " -> " ^ (eval_as_string_rec v))::accu
    in
    "{" ^ (String.concat ", " (Hashtbl.fold hash_aux d [])) ^ "}"

  | V_TlsRecord r -> Tls.string_of_record r
  | V_Asn1 o -> Asn1.string_of_object "" opts o
  | V_DN dn -> X509.string_of_dn "" (Some X509.name_directory) dn
  | V_Certificate c -> X509.string_of_certificate true "" (Some X509.name_directory) c

  | V_Unit | V_Function _ | V_Stream _ | V_OutChannel _
  | V_Lazy _ ->
    raise (ContentError "String expected")

let eval_as_int = function
  | V_Int i -> i
  | V_String s -> int_of_string s
  | _ -> raise (ContentError "Integer expected")

let eval_as_bool = function
  | V_Bool b -> b
  | V_Unit | V_Int 0 | V_List [] -> false
  | V_Int _ | V_List _ -> true
  | V_Set s -> StringSet.is_empty s
  | V_String s -> (String.length s) <> 0
  | V_Stream (_, s) -> not (Common.eos s)
  | V_Dict d -> (Hashtbl.length d) <> 0
  | V_ValueDict d -> (Hashtbl.length d) <> 0

  | V_TlsRecord _
  | V_Asn1 _ | V_DN _ | V_Certificate _ -> true

  | _ -> raise (ContentError "Boolean expected")

let eval_as_function = function
  | V_Function f -> f
  | _ -> raise (ContentError "Function expected")

let eval_as_stream = function
  | V_Stream (n, s) -> n, s
  | _ -> raise (ContentError "Function expected")

let eval_as_list = function
  | V_List l -> l
  | _ -> raise (ContentError "List expected")

let rec string_of_type = function
  | V_Unit -> "unit"
  | V_Bool _ -> "bool"
  | V_Int _ -> "int"
  | V_String _ -> "string"
  | V_Function _ -> "function"  (* TODO: arity? *)

  | V_List _ -> "list"
  | V_Set _ -> "set"
  | V_Dict d -> (try eval_as_string (Hashtbl.find d "dict_type") with Not_found -> "dict")
  | V_ValueDict _ -> "dict"
  | V_Stream _ -> "stream"
  | V_OutChannel _ -> "outchannel"
  | V_Lazy lazyval ->
    if Lazy.lazy_is_val lazyval
    then (string_of_type (Lazy.force lazyval)) else "lazy"

  | V_TlsRecord _ -> "TLSrecord"
  | V_Asn1 _ -> "asn1object"
  | V_DN _ -> "DN"
  | V_Certificate _ -> "certificate"

let strict_eval_value = function
  | V_Lazy lazyval -> Lazy.force lazyval
  | v -> v

let rec getv env name = match env with
  | [] -> raise Not_found
  | e::r -> begin
    try
      strict_eval_value (Hashtbl.find e name)
    with
      | Not_found -> getv r name
  end

let rec setv env name v = match env with
  | [] -> raise Not_found
  | [e] -> Hashtbl.replace e name v
  | e::r ->
    if Hashtbl.mem e name
    then Hashtbl.replace e name v
    else setv r name v

let getv_str env name default =
  try
    eval_as_string (getv env name)
  with
    | Not_found -> default
    | ContentError _ -> default


(* Interpretation *)

let rec  eval_string_token env = function
  | ST_String s -> s
  | ST_Var s -> eval_as_string_rec (getv env s)
  | ST_Expr s -> eval_as_string_rec (interpret_string env s)

and eval_exp env exp =
  let eval = eval_exp env in
  match exp with
    | E_Bool b -> V_Bool b
    | E_Int i -> V_Int i
    | E_String l -> V_String (String.concat "" (List.map (eval_string_token env) l))
    | E_Var s -> getv env s

    | E_Concat (a, b) -> V_String ((eval_as_string (eval a)) ^ (eval_as_string (eval b)))
    | E_Plus (a, b) -> V_Int ((eval_as_int (eval a)) + (eval_as_int (eval b)))
    | E_Minus (a, b) -> V_Int (eval_as_int (eval a) - eval_as_int (eval b))
    | E_Mult (a, b) -> V_Int (eval_as_int (eval a) * eval_as_int (eval b))
    | E_Div (a, b) -> V_Int (eval_as_int (eval a) / eval_as_int (eval b))
    | E_Mod (a, b) -> V_Int (eval_as_int (eval a) mod eval_as_int (eval b))

    | E_Equal (a, b) -> V_Bool (eval_equality env (eval a) (eval b))
    | E_Lt (a, b) -> V_Bool (match eval a, eval b with
	| V_Int i1, V_Int i2 -> i1 < i2
	| V_String s1, V_String s2 -> s1 < s2
	| v1, v2 -> eval_as_string v1 < eval_as_string v2
    )
    | E_In (a, b) -> V_Bool (eval_in env (eval a) (eval b))

    | E_Like (a, b) ->
      V_Bool (Str.string_match (Str.regexp (eval_as_string (eval b)))
		(eval_as_string (eval a)) 0)

    | E_LAnd (a, b) -> V_Bool (eval_as_bool (eval a) && eval_as_bool (eval b))
    | E_LOr (a, b) -> V_Bool (eval_as_bool (eval a) || eval_as_bool (eval b))
    | E_LNot e -> V_Bool (not (eval_as_bool (eval e)))

    | E_BAnd (a, b) -> V_Int (eval_as_int (eval a) land eval_as_int (eval b))
    | E_BOr (a, b) -> V_Int (eval_as_int (eval a) lor eval_as_int (eval b))
    | E_BXor (a, b) -> V_Int (eval_as_int (eval a) lxor eval_as_int (eval b))
    | E_BNot e -> V_Int (lnot (eval_as_int (eval e)))

    | E_Exists e -> begin
      try
	ignore (eval e);
	V_Bool true
      with Not_found -> V_Bool false
    end

    | E_Function (arg_names, e) ->
      let na = List.length arg_names in
      let new_env = Hashtbl.create (2 * na) in
      V_Function (InterpretedFun (new_env::env, arg_names, e))
    | E_Local ids ->
      let rec add_locals ids =
	match env, ids with
	  | _, [] -> V_Unit
	  | [], _ -> raise Not_found
	  | e::_, id::r ->
	    Hashtbl.replace e id V_Unit;
	    add_locals r
      in
      add_locals ids
    | E_Apply (e, args) -> begin
      let f_value = eval_as_function (eval e) in
      let arg_values = List.map eval args in
      eval_function env f_value arg_values
    end
    | E_Return e -> raise (ReturnValue (eval e))

    | E_List e -> V_List (List.map eval e)
    | E_Cons (e1, e2) -> V_List ((eval e1)::(eval_as_list (eval e2)))
    | E_GetField (e, f) -> strict_eval_value (match eval e with
	| V_Dict d -> (Hashtbl.find d f)
	| V_ValueDict d -> (Hashtbl.find d (V_String f))
	| V_Asn1 a -> (Hashtbl.find asn1_field_access f) a
	| V_Certificate c -> (Hashtbl.find certificate_field_access f) c
	| V_DN dn -> (Hashtbl.find dn_field_access f) dn
	| V_TlsRecord r -> (Hashtbl.find tls_field_access f) r
	| _ -> raise (ContentError ("Object with fields expected"))
    )

    | E_SetField (e, f, v) ->
      begin
	match eval e with
	  | V_Dict d -> (Hashtbl.replace d f (eval v))
	  | V_ValueDict d -> (Hashtbl.replace d (V_String f) (eval v))
	  | _ -> raise (ContentError ("Object with mutable fields expected"))
      end;
      V_Unit

    | E_Assign (var, e) ->
      setv env var (eval e);
      V_Unit
    | E_IfThenElse (i, t, e) ->
      eval_exps env (if (eval_as_bool (eval i)) then t else e)
    | E_While (cond, body) -> begin
      try
	while (eval_as_bool (eval cond)) do
	  try
	    ignore (eval_exps env body)
	  with Continue -> ()
	done;
	V_Unit;
      with Break -> V_Unit
    end
    | E_Continue -> raise Continue
    | E_Break -> raise Break

and eval_function env f args = match f with
  | NativeFun f -> f args
  | NativeFunWithEnv f -> f env args
  | InterpretedFun (saved_env::r, arg_names, body) ->
    let local_env = Hashtbl.copy saved_env in
    let rec instanciate_and_eval = function
      | [], [] -> begin
	try
	  eval_exps (local_env::r) body
	with
	  | ReturnValue v -> v
      end
      | remaining_names, [] ->
	V_Function (InterpretedFun (local_env::r, remaining_names, body))
      | name::names, value::values ->
	Hashtbl.replace local_env name value;
	instanciate_and_eval (names, values)
      | _ -> raise WrongNumberOfArguments
    in instanciate_and_eval (arg_names, args)
  | InterpretedFun _ -> failwith "eval_function called on an InterpretedFun with an empty saved_environment"

and eval_equality env a b =
  let rec equal_list = function
    | [], [] -> true
    | va::ra, vb::rb ->
      (eval_equality env va vb) && (equal_list (ra, rb))
    | _ -> false
  in
  match a, b with
    | V_Unit, V_Unit -> true
    | V_Bool b1, V_Bool b2 -> b1 = b2
    | V_Int i1, V_Int i2 -> i1 = i2
    | V_String s1, V_String s2 -> s1 = s2

    | V_List l1, V_List l2 -> equal_list (l1, l2)
    | V_Set s1, V_Set s2 -> StringSet.compare s1 s2 = 0

    | V_Dict d1, V_Dict d2 -> raise NotImplemented
    | V_ValueDict d1, V_ValueDict d2 -> raise NotImplemented

    | V_TlsRecord r1, V_TlsRecord r2 -> r1 = r2
    | V_Asn1 o1, V_Asn1 o2 -> o1 = o2
    | V_DN dn1, V_DN dn2 -> dn1 = dn2
    | V_Certificate c1, V_Certificate c2 -> c1 = c2

    | v1, v2 ->
      eval_as_string v1 = eval_as_string v2

and eval_in env a b =
  let rec eval_in_list = function
    | [] -> false
    | v::r -> (eval_equality env a v) || (eval_in_list r)
  in
  match b with
    | V_List l -> eval_in_list l
    | V_Set s -> StringSet.mem (eval_as_string a) s
    | _ -> raise (ContentError "List or set expected")


and eval_exps env = function
  | [] -> V_Unit
  | [e] -> eval_exp env e
  | e::r ->
    ignore (eval_exp env e);
    eval_exps env r

and interpret_string env s =
  let lexbuf = Lexing.from_string s in
  let ast = MapParser.exprs MapLexer.main_token lexbuf in
  eval_exps env ast
