open Lwt
open TlsEnums
open TlsContext
open Tls

type 'a tls_function = TlsContext.tls_context -> tls_record Lwt_mvar.t -> 'a Lwt.t

exception TLS_AlertToSend of tls_alert_type * string

type 'a tls_state =
  | FatalAlertReceived of tls_alert_type
  | FatalAlertToSend of tls_alert_type * string
  | FirstPhaseOK of tls_alert_type list * tls_alert_type list        (* warning alerts received and to send *)
  | NegotiationComplete of tls_alert_type list * tls_alert_type list (* warning alerts received and to send *)


(* CLIENT AUTOMATA *)

(* TODO: extensions *)
let update_with_client_hello ctx ch =
  ctx.future.versions_proposed <- (V_SSLv3, ch.client_version);
  ctx.future.s_client_random <- ch.client_random;
  ctx.future.s_session_id <- ch.client_session_id;
  ctx.future.ciphersuites_proposed <- ch.ciphersuites;
  ctx.future.compressions_proposed <- ch.compression_methods;
  match ch.client_extensions with
  | None | Some [] -> ()
  | _ -> failwith "Extensions not supported for now"


let set_server_version ctx v =
  let min, max = ctx.future.versions_proposed in
  ctx.future.s_version <- v;
  if not ((int_of_tls_version min < int_of_tls_version v) &&
	     (int_of_tls_version v < int_of_tls_version max))
  then raise (TLS_AlertToSend (AT_ProtocolVersion,
	        Printf.sprintf "A version between %s and %s was expected"
		  (print_tls_version 4 "" "" min) (print_tls_version 4 "" "" max)))

let set_ciphersuite ctx cs =
  ctx.future.s_ciphersuite <- cs;
  if  not (List.mem cs ctx.future.ciphersuites_proposed)
  then raise (TLS_AlertToSend (AT_HandshakeFailure, "Unexpected ciphersuite"))

let set_compression ctx cm =
  ctx.future.s_compression_method <- cm;
  if not (List.mem cm ctx.future.compressions_proposed)
  then raise (TLS_AlertToSend (AT_HandshakeFailure, "Unexpected compression method"))

let update_with_server_hello ctx sh =
  (* TODO: exts *)
  ctx.future.s_server_random <- sh.server_random;
  ctx.future.s_session_id <- sh.server_session_id;
  set_server_version ctx sh.server_version;
  set_ciphersuite ctx sh.ciphersuite;
  set_compression ctx sh.compression_method;
  match sh.server_extensions with
  | None | Some [] -> ()
  | _ -> failwith "Extensions not supported for now"

let update_with_certificate _ctx _cert = ()

let update_with_ske _ctx _cert = ()



let rec wrap_expect_fun f ctx recs =
  Lwt_mvar.take recs >>= fun record ->
  try
    begin
      match record.record_content with
      | Alert { alert_level = AL_Warning } ->
	wrap_expect_fun f ctx recs
      | Alert { alert_level = AL_Fatal; alert_type = t } ->
	return (FatalAlertReceived t)
      | rc -> f ctx recs rc
    end
  with
  | TLS_AlertToSend (at, s) -> return (FatalAlertToSend (at, s))
  | e -> return (FatalAlertToSend (AT_InternalError, (Printexc.to_string e)))


let rec _expect_server_hello ctx recs = function
  | Handshake {handshake_content = ServerHello sh} ->
    update_with_server_hello ctx sh;
    (* Expect certif, SKE or SHD *)
    expect_certificate ctx recs
  | _ -> raise (TLS_AlertToSend (AT_UnexpectedMessage, "ServerHello expected"))
and expect_server_hello ctx recs = wrap_expect_fun _expect_server_hello ctx recs

and _expect_certificate ctx recs = function
  | Handshake {handshake_content = Certificate cert} ->
      update_with_certificate ctx cert;
      (* Expect SKE or SHD *)
      expect_server_key_exchange ctx recs
  | _ -> raise (TLS_AlertToSend (AT_UnexpectedMessage, "Certificate expected"))
and expect_certificate ctx recs = wrap_expect_fun _expect_certificate ctx recs

and _expect_server_key_exchange ctx recs = function
  | Handshake {handshake_content = ServerKeyExchange ske} ->
    update_with_ske ctx ske;
    (* CertificateRequest ? *)
    expect_server_hello_done ctx recs
  | _ -> raise (TLS_AlertToSend (AT_UnexpectedMessage, "ServerKeyExchange expected"))
and expect_server_key_exchange ctx recs = wrap_expect_fun _expect_server_key_exchange ctx recs

and _expect_server_hello_done ctx recs = function
  | Handshake {handshake_content = ServerHelloDone ()} -> return (FirstPhaseOK ([], []))
  | _ -> raise (TLS_AlertToSend (AT_UnexpectedMessage, "ServerHelloDone expected"))
and expect_server_hello_done ctx recs = wrap_expect_fun _expect_server_hello_done ctx recs