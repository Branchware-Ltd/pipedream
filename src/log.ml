(* Among other things, this module wraps the Logs library so as to prepend
   request ids to log messages.

   However, instead of prepending the id at the front end of Logs, in the
   wrappers, we prepend the id at the back end instead - in the reporter. The
   rationale for this is that we want to (try to) prepend the id even to strings
   that don't come from Dream or the user's Dream app, and thus *definitely* do
   not call this module's wrappers.

   The wrappers try to get the request id from their argument ~request, and pass
   it down to the reporter in a Logs tag.

   The reporter reads the tag and uses that request id if it is available. If
   the request id is not available, it is because the log message comes from a
   point in the Dream app where an id has not been assigned to the request, or
   because the log message comes from another dependency (or a sloppy call
   site!). In that case, the reporter tries to retrieve the id from the
   promise-chain-local storage of Lwt.

   This is sufficient for attaching a request id to most log messages, in
   practice. *)

let logs_lib_tag : string Logs.Tag.def =
  Logs.Tag.def
    "dream.request_id"
    Format.pp_print_string



(* The "back end." I inlined several examples from the Logs, Logs_lwt, and Fmt
   docs into each other, and modified the result, to arrive at this function.
   See those docs for the meanings of the various helpers and values.

   The reporter needs to be suspended in a function because Dream sets up the
   logger lazily; it doesn't query the output streams for whether they are TTYs
   until needed. Setting up the reporter before TTY checking will cause it to
   not output color. *)
let reporter () =

  (* Format into an internal buffer. *)
  let buffer = Buffer.create 512 in
  let formatter = Fmt.with_buffer ~like:Fmt.stderr buffer in
  let flush () =
    let message = Buffer.contents buffer in
    Buffer.reset buffer;
    message
  in

  (* Gets called by Logs for each log call that passes its level threshold.
     ~over is to be called when the I/O underlying the log operation is fully
     complete. In practice, since most call sites are not using Lwt, they will
     continue executing anyway. This means that the message must be formatted
     and the buffer flushed before doing anything asynchronous, so that
     subsequent logging operations don't get into the same generation of the
     buffer.

     The user's_callback argument is not exactly the user's callback - it's the
     callback that got wrapped in function source (the "front end") below. That
     wrapper is the actual user's callback, and it calls user's_callback. *)
  let report src level ~over k user's_callback =

    let level_style, level =
      match level with
      | Logs.App ->     `White,   "     "
      | Logs.Error ->   `Red,     "ERROR"
      | Logs.Warning -> `Yellow,  " WARN"
      | Logs.Info ->    `Green,   " INFO"
      | Logs.Debug ->   `Blue,    "DEBUG"
    in

    let write _ =
      (* Get the formatted message out of the buffer right away, because we are
         doing Lwt operations next, and the caller might not wait. *)
      let message = flush () in

      (* Write the message. *)
      Lwt.async begin fun () ->
        Lwt.finalize
          (fun () -> Lwt_io.(write stderr) message)
          (fun () ->
            over ();
            Lwt.return_unit)
      end;

      k ()
    in

    (* Call the user's callback to get the actual message and trigger
       formatting, and, eventually, writing. The wrappers don't use the ?header
       argument, so we ignore it. *)
    user's_callback @@ fun ?header ?tags format_and_arguments ->
      ignore header;

      (* Format the current local time. For the millisecond fraction, be careful
         of rounding 999.5+ to 1000 on output. *)
      let time =
        let open Unix in
        let unix_time =
          gettimeofday () in
        let time =
          localtime unix_time in
        let fraction =
          fst (modf unix_time) *. 1000. in
        let clamped_fraction =
          if fraction > 999. then 999.
          else fraction
        in
        Printf.sprintf "%02i.%02i.%02i %02i:%02i:%02i.%03.0f"
          time.tm_mday time.tm_mon ((time.tm_year + 1900) mod 100)
          time.tm_hour time.tm_min time.tm_sec clamped_fraction
      in

      (* Format the source name column. It is the right-aligned log source name,
         clipped to the column width. If the source is the default application
         source, leave the column empty. *)
      let source =
        let width = 15 in
        if Logs.Src.equal src Logs.default then
          String.make width ' '
        else
          let name = Logs.Src.name src in
          if String.length name > width then
            String.sub name (String.length name - width) width
          else
            (String.make (width - String.length name) ' ') ^ name
      in

      (* Check if a request id is available in the tags passed from the front
         end. If not, try to get it from the promise-chain-local storage. If
         we end up with a request id, format it. *)
      let request_id_from_tags =
        match tags with
        | None -> None
        | Some tags ->
          Logs.Tag.find logs_lib_tag tags
      in

      let request_id =
        match request_id_from_tags with
        | Some _ -> request_id_from_tags
        | None ->
          Request_id.get_option ()
      in

      let request_id, request_style =
        match request_id with
        | Some "" | None -> "", `White
        | Some request_id ->
          (* The last byte of the request id is basically always going to be a
             digit, growing incrementally, so we can use the parity of its
             ASCII code to stripe the requests in the log. *)
          let last_byte = request_id.[String.length request_id - 1] in
          let color =
            if (Char.code last_byte) land 1 = 0 then
              `Cyan
            else
              `Magenta
          in
          " REQ " ^ request_id, color
      in

      (* The formatting proper. *)
      Format.kfprintf write formatter
        ("%a %s %a%a @[" ^^ format_and_arguments ^^ "@]@.")
        Fmt.(styled `Faint string) time
        source
        Fmt.(styled level_style string) level
        Fmt.(styled request_style (styled `Italic string)) request_id
  in

  {Logs.report}



(* Lazy initialization upon first use or call to initialize. *)
let enable =
  ref true

let level =
  ref Logs.Info

let set_printexc =
  ref true

let initializer_ = lazy begin
  if !enable then begin
    Fmt_tty.setup_std_outputs ();
    Logs.set_level ~all:true (Some !level);
    Logs.set_reporter (reporter ())
  end
end

type level = [
  | `Error
  | `Warning
  | `Info
  | `Debug
]

let initialize ?(backtraces = true) ?level:(level_ = `Info) ~enable:enable_ =
  if backtraces then
    Printexc.record_backtrace true;
  set_printexc := false;

  let level_ =
    match level_ with
    | `Error -> Logs.Error
    | `Warning -> Logs.Warning
    | `Info -> Logs.Info
    | `Debug -> Logs.Debug
  in

  enable := enable_;
  level := level_;

  Lazy.force initializer_



(* The "front end." *)
type source = {
  error : 'a. ('a, unit) Dream_.log;
  warning : 'a. ('a, unit) Dream_.log;
  info : 'a. ('a, unit) Dream_.log;
  debug : 'a. ('a, unit) Dream_.log;
}

let source name =
  (* This creates a wrapper, as described above. The wrapper forwards to a
     logger of the Logs library, but instead of passing the formatter m to the
     user's callback, it passes a formatter m', which is like m, but lacks a
     ?tags argument. It has a ?request argument instead. If ~request is given,
     m' immediately tries to retrieve the request id, put it into a Logs tag,
     and call Logs' m with the user's formatting arguments and the tag. *)
  let forward ~(destination_log : _ Logs.log) user's_k =
    Lazy.force initializer_;

    destination_log (fun m ->
      user's_k (fun ?request format_and_arguments ->
        let tags =
          match request with
          | None -> Logs.Tag.empty
          | Some request ->
            match Request_id.get_option ~request () with
            | None -> Logs.Tag.empty
            | Some request_id ->
              Logs.Tag.add logs_lib_tag request_id Logs.Tag.empty
        in
        m ~tags format_and_arguments))
  in

  (* Create the actual Logs source, and then wrap all the interesting
     functions. *)
  let (module Log) = Logs.src_log (Logs.Src.create name) in

  {
    error =   (fun k -> forward ~destination_log:Log.err   k);
    warning = (fun k -> forward ~destination_log:Log.warn  k);
    info =    (fun k -> forward ~destination_log:Log.info  k);
    debug =   (fun k -> forward ~destination_log:Log.debug k);
  }



(* Use the above function to create a log source for Log's own middleware, the
   same way any other middleware would. *)
let log = source "dream.log"

(* The requst logging middleware. *)
let log_traffic next_handler request =

  (* Turn on backtrace recording. *)
  if !set_printexc then begin
    Printexc.record_backtrace true;
    set_printexc := false
  end;

  (* Identify the request in the log. *)
  let user_agent =
    Dream_.headers_named "User-Agent" request
    |> String.concat " "
  in

  log.info (fun m ->
    m ~request "%s %s %s %s"
      (Dream_.method_to_string (Dream_.method_ request))
      (Dream_.target request)
      (Dream_.client request)
      user_agent);

  (* Start timing handling of the request, and call into the rest of the app. *)
  let start = Unix.gettimeofday () in
  Lwt.try_bind
    (fun () ->
      next_handler request)
    (fun response ->
      let elapsed = Unix.gettimeofday () -. start in

      (* Log the elapsed time. If the response is a redirection, log the
         target. *)
      let location =
        match Dream_.header_option "Location" response with
        | Some location -> location
        | None -> ""
      in

      log.info (fun m -> m ~request "%i%s in %.0f μs"
        (Dream_.status_to_int (Dream_.status response))
        location
        (elapsed *. 1e6));

      Lwt.return response)

    (fun exn ->
      (* In case of exception, log the exception and the backtrace. *)
      log.error (fun m -> m ~request "Aborted by %s" (Printexc.to_string exn));

      Printexc.get_backtrace ()
      |> String.split_on_char '\n'
      |> List.filter (fun s -> s <> "")
      |> List.iter (fun s -> log.error (fun m -> m ~request "%s" s));

      Lwt.fail exn)



(* TODO DOC Add docs on how to avoid OCamlbuild dep. *)
(* TODO DOC recommending logs-ppx... or something else? *)
(* TODO DOC why it's good to use the initializer early. *)

(* TODO LATER implement fire. *)
