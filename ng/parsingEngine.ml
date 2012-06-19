type string_input = {
  str : string;
  cur_name : string;
  cur_base : int;
  mutable cur_offset : int;
  cur_length : int;
  history : (string * int * int option) list
}

exception OutOfBounds of string_input
exception UnexptedTrailingBytes of string_input
exception EmptyHistory

let emit_eos_expected _fatal i = raise (UnexptedTrailingBytes i)


let input_of_string name s =
  {
    str = s;
    cur_name = name;
    cur_base = 0;
    cur_offset = 0;
    cur_length = String.length s;
    history = []
  }

let get_in input name len =
  if input.cur_offset + len <= input.cur_length
  then {
    str = input.str;
    cur_name = name;
    cur_base = input.cur_base + input.cur_offset;
    cur_offset = 0;
    cur_length = len;
    history = (input.cur_name, input.cur_offset, Some input.cur_length)::input.history
  } else raise (OutOfBounds input)

let get_out old_input input =
  if input.cur_offset < input.cur_length
  then raise (UnexptedTrailingBytes input)
  else old_input.cur_offset <- old_input.cur_offset + input.cur_length


(* Integer parsing *)

let parse_uint8 input =
  if input.cur_offset < input.cur_length then begin
    let res = int_of_char (input.str.[input.cur_base + input.cur_offset]) in
    input.cur_offset <- input.cur_offset + 1;
    res
  end else raise (OutOfBounds input)

let parse_char input =
  if input.cur_offset < input.cur_length then begin
    let res = input.str.[input.cur_base + input.cur_offset] in
    input.cur_offset <- input.cur_offset + 1;
    res
  end else raise (OutOfBounds input)

let parse_uint16 input =
  if input.cur_offset + 2 <= input.cur_length then begin
    let res =
      (int_of_char (input.str.[input.cur_base + input.cur_offset]) lsl 8) lor
	(int_of_char (input.str.[input.cur_base + input.cur_offset + 1]))
    in
    input.cur_offset <- input.cur_offset + 2;
    res
  end else raise (OutOfBounds input)

let parse_uint24 input =
  if input.cur_offset + 3 <= input.cur_length then begin
    let res =
      (int_of_char (input.str.[input.cur_base + input.cur_offset]) lsl 16) lor
      (int_of_char (input.str.[input.cur_base + input.cur_offset + 1]) lsl 8) lor
	(int_of_char (input.str.[input.cur_base + input.cur_offset + 2]))
    in
    input.cur_offset <- input.cur_offset + 3;
    res
  end else raise (OutOfBounds input)

let parse_uint32 input =
  if input.cur_offset + 2 <= input.cur_length then begin
    let res =
      (int_of_char (input.str.[input.cur_base + input.cur_offset]) lsl 24) lor
      (int_of_char (input.str.[input.cur_base + input.cur_offset + 1]) lsl 16) lor
      (int_of_char (input.str.[input.cur_base + input.cur_offset + 2]) lsl 8) lor
	(int_of_char (input.str.[input.cur_base + input.cur_offset + 3]))
    in
    input.cur_offset <- input.cur_offset + 4;
    res
  end else raise (OutOfBounds input)



(* String parsing *)

let parse_string n input =
  if input.cur_offset + n <= input.cur_length then begin
    let res = String.sub input.str (input.cur_base + input.cur_offset) n in
    input.cur_offset <- input.cur_offset + n;
    res
  end else raise (OutOfBounds input)

let parse_rem_string input =
  let res = String.sub input.str (input.cur_base + input.cur_offset) (input.cur_length - input.cur_offset) in
  input.cur_offset <- input.cur_length;
  res

let parse_varlen_string name len_fun input =
  let n = len_fun input in
  let new_input = get_in input name n in
  let res = parse_string n new_input in
  get_out input new_input;
  res

let drop_bytes n input =
  if input.cur_offset + n <= input.cur_length
  then input.cur_offset <- input.cur_offset + n
  else raise (OutOfBounds input)

let drop_rem_bytes input =
  input.cur_offset <- input.cur_length

let eos input =
  input.cur_offset >= input.cur_length

let check_empty_input fatal input =
  if not (eos input) then emit_eos_expected fatal input



(* List parsing *)

let parse_list n parse_fun input =
  let rec aux accu = function
    | 0 -> List.rev accu
    | i ->
      let x = parse_fun input in
      aux (x::accu) (i-1)
  in aux [] n

let parse_rem_list parse_fun input =
  let rec aux accu =
    if eos input
    then List.rev accu
    else begin
      let x = parse_fun input in
      aux (x::accu)
    end
  in aux []

let parse_varlen_list name len_fun parse_fun input =
  let n = len_fun input in
  let new_input = get_in input name n in
  let res = parse_rem_list parse_fun new_input in
  get_out input new_input;
  res

let parse_container name len_fun parse_fun input =
  let n = len_fun input in
  let new_input = get_in input name n in
  let res = parse_fun new_input in
  get_out input new_input;
  res
