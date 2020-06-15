open Stdune

let int_of_string ?where s =
  match Int.of_string s with
  | Some s -> Ok s
  | None ->
    Result.Error
      (Printf.sprintf "invalid integer%s: %s"
         ( match where with
         | Some l -> " in " ^ l
         | None -> "" )
         s)

let retry ?message ?(count = 100) f =
  let rec loop = function
    | x when x >= count ->
      Result.Error
        (Failure
           ( Printf.sprintf "too many retries (%i)" x
           ^
           match message with
           | None -> ""
           | Some msg -> ": " ^ msg ))
    | x -> (
      match f () with
      | Some v -> Result.Ok v
      | None ->
        Thread.delay 0.1;
        loop (x + 1) )
  in
  loop 0

module LwtO = struct
  include Lwt.Infix

  let ( let* ) = ( >>= )

  let ( let+ ) = ( >|= )
end

module LwtrO = struct
  include Lwt_result.Infix

  let ( let* ) = ( >>= )

  let ( let+ ) = ( >|= )
end

(** A barrier that let thread throughs after it has been opened for some
    duration. Enables to postpone low priority operations until main operations
    have been silent for some time. *)
module Barrier = struct
  open LwtO

  type t =
    { mutable open_ : bool
    ; mutable time : float
    ; mutable promise : unit Lwt.t
    ; mutable resolve : unit Lwt.u
    ; threshold : float
    }

  let make ?(threshold = 0.1) () =
    let promise, resolve = Lwt.wait () in
    { open_ = true; time = Unix.gettimeofday (); promise; resolve; threshold }

  let open_ = function
    | { open_ = true; _ } -> ()
    | { resolve; _ } as b ->
      let p, r = Lwt.wait () in
      b.open_ <- true;
      b.time <- Unix.gettimeofday ();
      b.promise <- p;
      b.resolve <- r;
      Lwt.wakeup resolve ()

  let close b = b.open_ <- false

  let rec wait = function
    | { open_ = true; time; _ } as b ->
      let now = Unix.gettimeofday () in
      let elapsed = now -. time in
      if elapsed > b.threshold then
        Lwt.return ()
      else
        let%lwt () = Lwt_unix.sleep (b.threshold -. elapsed) in
        wait b
    | { promise; _ } as b ->
      let* () = promise in
      wait b

  let use b f =
    close b;
    match%lwt f () with
    | e ->
      open_ b;
      Lwt.return e
    | exception e ->
      open_ b;
      raise e
end

let mkdir p =
  try%lwt Lwt_unix.mkdir p 0o700
  with Unix.Unix_error (Unix.EEXIST, _, _) -> Lwt.return ()

(** Write file in an atomic manner. *)
let write_file local path executable contents =
  try%lwt
    Lwt.map Result.ok
    @@
    let dir = path |> Path.parent_exn |> Path.to_string
    and path_tmp =
      path |> Path.basename |> Path.relative (Local.tmp local) |> Path.to_string
    and path = path |> Path.to_string
    and perm =
      if executable then
        0o500
      else
        0o400
    in
    let%lwt () =
      let write () =
        let%lwt output = Lwt_io.open_file ~perm ~mode:Lwt_io.output path_tmp in
        let%lwt () = Lwt_io.write output contents in
        Lwt_io.close output
      in
      Local.throttle_fd local write
    and () = mkdir dir in
    Lwt_unix.rename path_tmp path
  with
  | Unix.Unix_error (Unix.EACCES, _, _) ->
    (* If the file exists with no write permissions, it is being pulled as part
       of another hinting. *)
    Lwt_result.return ()
  | Unix.Unix_error (e, f, a) ->
    Lwt_result.fail (Printf.sprintf "%s: %s %s" (Unix.error_message e) f a)
