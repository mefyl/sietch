open Cmdliner
open Stdune

let ( let+ ) term f = Term.app (Term.const f) term

let ( and+ ) a b = Term.(const (fun x y -> (x, y)) $ a $ b)

let man =
  [ `S "DESCRIPTION"
  ; `P
      {|Dune is able to share build artifacts between workspaces.
        $(b,dune_cache_daemon) is a daemon that runs in the background
        and manages this shared cache. For instance, it makes sure that it
        does not grow too big and try to maximise sharing between the various
        workspace that are using the shared cache.|}
  ; `P
      {|The daemon is automatically started by Dune when the shared cache is
        enabled. You do not need to run this command manually.|}
    (* ; `S "ACTIONS"
     * ; `P {|$(b,start) starts the daemon if not already running.|}
     * ; `P {|$(b,stop) stops the daemon.|}
     * ; `P {|$(b,trim) remove oldest files from the cache to free space.|} *)
  ]

let doc = "dune binary artifact distributed cache daemon"

let default =
  let term =
    Term.ret
    @@ let+ _ = Term.const () in
       `Help (`Pager, None)
  in
  (term, Term.info "dune_cache_daemon" ~doc ~man)

let path_conv =
  let pp formatter path =
    Format.pp_print_string formatter @@ Path.to_string path
  in
  ((fun s -> `Ok (Path.of_string s)), pp)

let port_path =
  Arg.(
    value
    & opt path_conv (Dune_cache_daemon.Daemon.default_port_file ())
    & info ~docv:"PATH" [ "port-file" ]
        ~doc:"The file to read/write the daemon port to/from.")

let start =
  let doc = "start daemon"
  and man =
    [ `S "DESCRIPTION"; `P {|Start the daemon if not already running.|} ]
  and term =
    let+ exit_no_client =
      let doc = "Whether to exit once all clients have disconnected" in
      Arg.(
        value & flag
        & info [ "exit-no-client" ] ~doc
            ~env:(Arg.env_var "DUNE_CACHE_EXIT_NO_CLIENT" ~doc))
    and+ foreground =
      Arg.(
        value & flag
        & info [ "foreground"; "f" ]
            ~doc:"Whether to start in the foreground or as a daeon")
    and+ port_path = port_path
    and+ root =
      Arg.(
        value
        & opt path_conv (Cache.Local.default_root ())
        & info ~docv:"PATH" [ "root" ] ~doc:"Root of the dune cache")
    in
    let show_endpoint ep = Printf.printf "%s\n%!" ep
    and config : Dune_cache_daemon.Daemon.config = { exit_no_client } in
    let f started =
      let started daemon_info =
        if foreground then show_endpoint daemon_info;
        started ~daemon_info
      in
      Dune_cache_daemon.Daemon.daemon ~root ~config started
    in
    match Daemonize.daemonize ~workdir:root ~foreground port_path f with
    | Result.Ok Finished -> ()
    | Result.Ok (Daemonize.Started { daemon_info = endpoint; _ }) ->
      show_endpoint endpoint
    | Result.Ok (Daemonize.Already_running { daemon_info = endpoint; _ })
      when not foreground ->
      show_endpoint endpoint
    | Result.Ok (Daemonize.Already_running { daemon_info = endpoint; pid }) ->
      User_error.raise
        [ Pp.textf "already running on %s (PID %i)" endpoint (Pid.to_int pid) ]
    | Result.Error reason -> User_error.raise [ Pp.text reason ]
  in
  (term, Term.info "start" ~doc ~man)

let stop =
  let doc = "stop daemon"
  and man = [ `S "DESCRIPTION"; `P {|Stop the daemon.|} ]
  and term =
    let+ port_path = port_path in
    match Daemonize.stop port_path with
    | Error s -> User_error.raise [ Pp.text s ]
    | Ok () -> ()
  in
  (term, Term.info "stop" ~doc ~man)

let commands = [ start; stop ]

let () =
  Printexc.record_backtrace true;
  let () =
    Dune_util.Log.init
      ~file:(Dune_util.Log.File.This (Path.of_string "/dev/stdout"))
      ()
  in
  try
    match Term.eval_choice default commands ~catch:false with
    | `Error _ -> exit 1
    | _ -> exit 0
  with exn ->
    let exn = Exn_with_backtrace.capture exn in
    Dune_util.Report_error.report exn