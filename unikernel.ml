(* (c) 2019 Hannes Mehnert, all rights reserved *)

open Lwt.Infix

module Main (Keys : Mirage_kv.RO) (Pclock : Mirage_clock.PCLOCK) (Public : Mirage_stack.V4V6) (Private : Mirage_stack.V4V6) = struct

  module X509 = Tls_mirage.X509(Keys)(Pclock)
  module TLS = Tls_mirage.Make(Public.TCP)

  let rec read_tls_write_tcp tls tcp =
    TLS.read tls >>= function
    | Error e ->
      Logs.err (fun m -> m "TLS read error %a" TLS.pp_error e);
      Private.TCP.close tcp
    | Ok `Eof ->
      Logs.info (fun m -> m "TLS read eof");
      Private.TCP.close tcp
    | Ok `Data buf ->
      Private.TCP.write tcp buf >>= function
      | Error e ->
        Logs.err (fun m -> m "TCP write error %a" Private.TCP.pp_write_error e);
        TLS.close tls
      | Ok () ->
        read_tls_write_tcp tls tcp

  let rec read_tcp_write_tls tcp tls =
    Private.TCP.read tcp >>= function
    | Error e ->
      Logs.err (fun m -> m "TCP read error %a" Private.TCP.pp_error e);
      TLS.close tls
    | Ok `Eof ->
      Logs.warn (fun m -> m "TCP read eof");
      TLS.close tls
    | Ok `Data buf ->
      TLS.write tls buf >>= function
      | Error e ->
        Logs.err (fun m -> m "TLS write error %a" TLS.pp_write_error e);
        Private.TCP.close tcp
      | Ok () ->
        read_tcp_write_tls tcp tls

  let tls_accept priv config tcp_flow =
    (* TODO this should timeout with a reasonable timer *)
    TLS.server_of_flow config tcp_flow >>= function
    | Error e ->
      Logs.warn (fun m -> m "TLS error %a" TLS.pp_write_error e);
      Public.TCP.close tcp_flow
    | Ok tls_flow ->
      let backend_ip = Key_gen.backend_ip ()
      and backend_port = Key_gen.backend_port ()
      in
      Private.TCP.create_connection priv (backend_ip, backend_port) >>= function
      | Error e ->
        Logs.err (fun m -> m "error %a connecting to backend"
                     Private.TCP.pp_error e);
        TLS.close tls_flow
      | Ok tcp_flow ->
        Lwt.join [
          read_tls_write_tcp tls_flow tcp_flow ;
          read_tcp_write_tls tcp_flow tls_flow
        ]

  let tls_init kv =
    X509.certificate kv `Default >|= fun cert ->
    Tls.Config.server ~certificates:(`Single cert) ()

  let start kv _ pub priv =
    let frontend_port = Key_gen.frontend_port () in
    tls_init kv >>= fun config ->
    let priv_tcp = Private.tcp priv in
    Public.listen_tcp pub ~port:frontend_port (tls_accept priv_tcp config);
    (* waiting - could call Public.listen pub, but that's pointless *)
    fst (Lwt.task ())
end
