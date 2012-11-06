open Common
open Lwt
open Mrt
open Parsifal
open PTypes
open Getopt


let string_of_ipv6 raw_s = Socket.inet_ntop Socket.AF_INET6 raw_s

let string_of_ip_prefix_space ip_prefix =
  let a, len = match ip_prefix with
    | IPv4Prefix (s, prefix_length) ->
      let l = (prefix_length + 7) / 8 in
      string_of_ipv4 (s ^ (String.make (4 - l) '\x00')), prefix_length
    | IPv6Prefix (s, prefix_length) ->
      let l = (prefix_length + 7) / 8 in
      string_of_ipv6 (s ^ (String.make (16 - l) '\x00')), prefix_length
  in Printf.sprintf "%s %d" a len



type action =
  | JustParse
  | PrettyPrint
  | ObsDump
let action = ref PrettyPrint

let set_action v = TrivialFun (fun () -> action := v)

(* PrettyPrint options *)
type pretty_mode =
  | StandardMode
  | RawMode
  | SafeMode
let pretty_mode = ref StandardMode

let set_mode m = TrivialFun (fun () -> pretty_mode := m)

(* ObsDump options *)
let do_degrees = ref false
let asn_to_watch = Hashtbl.create 10

let add_asn x =
  do_degrees := true;
  Hashtbl.add asn_to_watch x 0;
  ActionDone

let add_asn_file fn =
  let f = open_in fn in
  try
    while true do
      ignore (add_asn (int_of_string (input_line f)))
    done;
    ActionDone
  with
    | End_of_file -> ActionDone
    | e -> ShowUsage (Some "Error while reading the list of ASN to watch")


let stop_after_RIB t st _ = match t, st with
  | MT_TABLE_DUMP_V2, MST_TABLE_DUMP_V2 RIB_IPV4_UNICAST -> fail (Failure "STOP")
  | _ -> return ()

let options = [
  mkopt (Some 'h') "help" Usage "show this help";

  mkopt None "pretty" (set_action PrettyPrint) "simply display message";
  mkopt None "raw" (set_mode RawMode) "do not parse in depth the MRT messages (in pretty mode)";
  mkopt None "safe" (set_mode SafeMode) "activate safe mode (in pretty mode)";

  mkopt None "silent" (set_action JustParse) "silent mode";

  mkopt None "obsdump" (set_action ObsDump) "obsdump mode";
  mkopt (Some 'W') "watch-asn" (IntFun add_asn) "add an ASN to watch";
  mkopt None "degrees" (StringFun add_asn_file) "watch the ASN listed in the file given"
]

let getopt_params = {
  default_progname = "test_mrt";
  options = options;
  postprocess_funs = [];
}



(* ObsDump *)


let peers = ref []

let int_of_asn = function
  | AS16 x | AS32 x -> x
  | _ -> failwith "Unknown AS format"

let string_from46 ip asn =
  match ip with
  | IPA_IPv4 a -> Printf.sprintf "F4 %s %u" (string_of_ipv4 a) (int_of_asn asn)
  | IPA_IPv6 a -> Printf.sprintf "F6 %s %u" (string_of_ipv6 a) (int_of_asn asn)
  | _ -> failwith "Invalid IPA"

let print_from46 ip asn = print_endline (string_from46 ip asn)

let rec list_until l n = match l, n with
    _, 0 -> []
  | x::r, _ -> x::(list_until r (n-1))
  | [], _ -> failwith "Invalid input"

(** Merge AS_PATH and AS4_PATH.
    The methodology is described in RFC 4893, page 5. *)
let merge_as_path attr_lst =
  let internal attr_lst ap a4p =
    let rec _get_asn = function
      | { path_segment_type = (AS_SET|AS_SEQUENCE);
	  path_segment_value = e } -> List.map int_of_asn e
      | _ -> failwith "Invalid ASPath attribute"
    in
    let get_asn = function
      | { attr_content = BAC_ASPath l } ->
	List.flatten (List.map _get_asn l)
      | _ -> failwith "Invalid ASPath attribute"
    in

    let ap_list = get_asn ap
    and a4p_list = get_asn a4p in
    let ap_len = List.length ap_list
    and a4p_len = List.length a4p_list in
    if ap_len < a4p_len then a4p
    else begin
      match a4p.attr_content with
	| BAC_ASPath asp ->
	  let new_path = (list_until ap_list (ap_len-a4p_len))@a4p_list in
	  (* TODO: CHECK THIS *)
	  let new_as_set = { path_segment_type = AS_SEQUENCE; (* ?? SET ?? *)
			     path_segment_length = List.length new_path;
			     path_segment_value = List.map (fun x -> AS32 x) new_path }
	  in
	  { a4p with attr_content = (BAC_ASPath ([new_as_set])); }
	| _ -> failwith "Invalid ASPath attribute"
    end
  in
    let ap = List.filter (fun x -> x.attr_type = AS_PATH) attr_lst in
    let a4p = List.filter (fun x -> x.attr_type = AS4_PATH) attr_lst in
    (* Decide to keep or merge attributes. *)
    match List.length ap, List.length a4p with
      | 0,0 -> []
      | 1,0 -> ap
      | 0,1 -> a4p
      | 1,1 -> [internal attr_lst (List.hd ap) (List.hd a4p)]
      | a,b -> failwith (Printf.sprintf "merge_as_path: can't handle these set of AS*_PATH (%i %i) !\n" a b)


(** Print ASN list and AS neighbors *)
let print_asn_list_degree str_prefix l as2w =
  let neighbors = ref [] in

  let rec pap l =
    let rec p l previous_node =
      match l with
      | (AS16 e)::r | (AS32 e)::r ->
	if !do_degrees then begin
	  match previous_node with
	    | Some p_as when p_as <> e ->
	      if Hashtbl.mem as2w e then neighbors := (e, p_as)::(!neighbors);
	      if Hashtbl.mem as2w p_as then neighbors := (p_as, e)::(!neighbors)
	    | _ -> ()
	end;
	(string_of_int e)::(p r (Some e))
      | _::r -> p r previous_node
      | [] -> []
    in
    match l with
    | { path_segment_type = AS_SET;
	path_segment_value = e }::r ->
      (Printf.sprintf "{%s}" (String.concat "," (p e None)))::(pap r)
    | { path_segment_type = AS_SEQUENCE;
	path_segment_value = e }::r ->
      (String.concat " " (p e None))::(pap r)
    | _::r -> pap r
    | [] -> []
  in begin
    match l with
      | [] -> Printf.printf "%s\n" str_prefix
      | _  -> Printf.printf "%s %s\n" str_prefix (String.concat " " (pap l))
  end;
  List.iter (fun (a, b) -> Printf.printf "NE %u %u\n" a b) (List.rev !neighbors)


let print_as_path str_prefix = function
  | { attr_content = BAC_ASPath path_segments } ->
    print_asn_list_degree str_prefix path_segments asn_to_watch
  | _ -> ()

let print_prefixes str = function
  | IPv4Prefix _ as p -> Printf.printf "%s4 %s\n" str (string_of_ip_prefix_space p)
  | IPv6Prefix _ as p -> Printf.printf "%s6 %s\n" str (string_of_ip_prefix_space p)

let print_reach_nlri = function
  | { attr_type = MP_REACH_NLRI;
      attr_content = BAC_MPReachNLRI (FullNLRI { rn_afi = AFI_IPv6; rn_nlri = prefixes }) } ->
    List.iter (print_prefixes "A") prefixes
  | { attr_type = MP_UNREACH_NLRI;
      attr_content = BAC_MPUnreachNLRI { un_afi = AFI_IPv6; un_withdrawn_routes = prefixes} } ->
    List.iter (print_prefixes "W") prefixes
  | _ -> ()


let print_table_dump ts prefix entries str =

  let print_re = function
    { rib_peer_index = n; rib_originated_time = ts; rib_attribute = attr } ->
      let peer = List.nth !peers n in
      Printf.printf "%s %u" (string_from46 peer.pe_peer_ip_address peer.pe_peer_as) ts;
      List.iter (print_as_path "") (merge_as_path attr)
  in
    Printf.printf "%s %u\n" str ts;
    List.iter (print_prefixes "P") [prefix];
    List.iter print_re entries;
    print_newline ()


let obsdump mrt = match mrt.mrt_type, mrt.mrt_subtype, mrt.mrt_message with
  | MT_TABLE_DUMP_V2, MST_TABLE_DUMP_V2 PEER_INDEX_TABLE, PeerIndexTable pit ->
    peers := pit.pit_peer_entries
  | MT_TABLE_DUMP_V2, MST_TABLE_DUMP_V2 (RIB_IPV4_UNICAST|RIB_IPV4_MULTICAST), RIB rib ->
    print_table_dump mrt.mrt_timestamp rib.rib_prefix rib.rib_entries "T4"
  | MT_TABLE_DUMP_V2, MST_TABLE_DUMP_V2 (RIB_IPV6_UNICAST|RIB_IPV6_MULTICAST), RIB rib ->
    print_table_dump mrt.mrt_timestamp rib.rib_prefix rib.rib_entries "T6"
  | MT_BGP4MP, MST_BGP4MP (BGP4MP_MESSAGE|BGP4MP_MESSAGE_AS4),
    BGP4MP_Message
      { bm_peer_as_number = pa;
	bm_peer_ip_address = pi;
	bm_bgp_message =
	  { bgp_message_type = BMT_UPDATE;
	    bgp_message_content = BGP_Update
	      { withdrawn_routes = wr;
		path_attributes = attr;
		network_layer_reachability_information = prefixes
	      }
	  }
      } ->
    if (List.length wr) + (List.length attr) + (List.length prefixes) > 0
    then begin
      Printf.printf "UP %u\n" mrt.mrt_timestamp;
      print_from46 pi pa;
      List.iter (print_as_path "AP") (merge_as_path attr);
      List.iter print_reach_nlri attr; (* IPv6 only *)
      List.iter (print_prefixes "W") wr;
      List.iter (print_prefixes "A") prefixes;
      print_newline ()
    end
  | _ -> ()


let input_of_filename filename =
  Lwt_unix.openfile filename [Unix.O_RDONLY] 0 >>= fun fd ->
  input_of_fd filename fd


let rec just_parse input =
  lwt_parse_mrt_message input >>= fun _mrt_msg ->
  just_parse input

let rec pretty_parse input =
  lwt_parse_mrt_message input >>= fun mrt_msg ->
  let real_msg = match !pretty_mode with
    | SafeMode ->
      enrich_mrt_message_content := true;
      let res =
	try parse_mrt_message (input_of_string "" (dump_mrt_message mrt_msg))
	with _ -> mrt_msg
      in
      enrich_mrt_message_content := false;
      res
    | _ -> mrt_msg
  in print_endline (print_mrt_message real_msg);
  pretty_parse input

let rec obsdump_parse input =
  lwt_parse_mrt_message input >>= fun mrt_msg ->
  obsdump mrt_msg;
  obsdump_parse input


let handle_input input =
  match !action, !pretty_mode with
    | PrettyPrint, (SafeMode | RawMode) ->
      enrich_mrt_message_content := false;
      pretty_parse input
    | PrettyPrint, _ -> pretty_parse input
    | ObsDump, _ -> obsdump_parse input
    | JustParse, _ -> just_parse input

let _ =
  let args = parse_args getopt_params Sys.argv in
  let t = match args with
    | [] -> input_of_channel "(stdin)" Lwt_io.stdin >>= handle_input
    | [filename] -> input_of_filename filename >>= handle_input
    | _ -> failwith "Too many files given"
  in
  try Lwt_unix.run t;
  with
    | End_of_file -> ()
    | ParsingException (e, h) -> prerr_endline (string_of_exception e h)
    | e -> prerr_endline (Printexc.to_string e)
