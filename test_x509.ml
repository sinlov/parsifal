open Lwt
open Common
open Parsifal
open Asn1PTypes
open X509
open X509Util
open RSAKey
open Getopt

type action = Text | Subject | Issuer | Serial | CheckSelfSigned

let verbose = ref false
let keep_going = ref false
let action = ref Text

let options = [
  mkopt (Some 'h') "help" Usage "show this help";
  mkopt (Some 'v') "verbose" (Set verbose) "print more info to stderr";
  mkopt (Some 'k') "keep-going" (Set keep_going) "keep working even when errors arise";

  mkopt (Some 't') "text" (TrivialFun (fun () -> action := Text)) "prints the certificates given";
  mkopt (Some 'S') "serial" (TrivialFun (fun () -> action := Serial)) "prints the certificates serial number";
  mkopt (Some 's') "subject" (TrivialFun (fun () -> action := Subject)) "prints the certificates subject";
  mkopt (Some 'i') "issuer" (TrivialFun (fun () -> action := Issuer)) "prints the certificates issuer";
  mkopt None "check-selfsigned" (TrivialFun (fun () -> action := CheckSelfSigned)) "checks the signature of a self signed";
]

let getopt_params = {
  default_progname = "test_x509";
  options = options;
  postprocess_funs = [];
}


let handle_input input =
  lwt_parse_certificate input >>= fun certificate ->
  match !action with
    | Serial ->
      print_endline (hexdump certificate.tbsCertificate.serialNumber);
      return ()
    | CheckSelfSigned ->
      let result = match (* TODO: certificate.tbsCertificate._raw_tbsCertificate*) None,
	certificate.tbsCertificate.subjectPublicKeyInfo.subjectPublicKey,
	certificate.signatureValue
	with
	| Some m, RSA {p_modulus = n; p_publicExponent = e}, (0, s) ->
	  Pkcs1.raw_verify 1 m s n e
	| _ -> false
      in
      print_endline (string_of_bool (result));
      return ()
    | Subject ->
      let extract_string atv = match atv.attributeValue with
	| { Asn1PTypes.a_content = String (s, _)} -> "\"" ^ s ^ "\""
	| _ -> "\"\""
      in
      print_endline ("[" ^ String.concat ", " (List.map extract_string (List.flatten certificate.tbsCertificate.subject)) ^ "]");
      return ()
    | Issuer ->
      let extract_string atv = match atv.attributeValue with
	| { Asn1PTypes.a_content = String (s, _)} -> "\"" ^ s ^ "\""
	| _ -> "\"\""
      in
      print_endline ("[" ^ String.concat ", " (List.map extract_string (List.flatten certificate.tbsCertificate.issuer)) ^ "]");
      return ()
    | Text ->
      print_endline (print_certificate certificate);
      return ()

let input_of_filename filename =
  Lwt_unix.openfile filename [Unix.O_RDONLY] 0 >>= fun fd ->
  input_of_fd filename fd

let catch_exceptions e =
  if !keep_going
  then begin
    prerr_endline (Printexc.to_string e);
    return ()
  end else fail e

let rec iter_on_names = function
  | [] -> return ()
  | f::r ->
    let t = input_of_filename f >>= handle_input in
    catch (fun () -> t) catch_exceptions >>= fun () ->
    iter_on_names r



let _ =
  let args = parse_args getopt_params Sys.argv in
  let t = match args with
    | [] -> input_of_channel "(stdin)" Lwt_io.stdin >>= handle_input
    | _ -> iter_on_names args
  in
  try
    Lwt_unix.run t;
    exit 0
  with
    | ParsingException (e, h) -> prerr_endline (string_of_exception e h); exit 1
    | e -> prerr_endline (Printexc.to_string e); exit 1
