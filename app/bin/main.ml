open Ppx_yojson_conv_lib.Yojson_conv.Primitives
open Yojson.Safe.Util

(* 
type note = {
  id: string;
  body: string;
  votes: string list;
  todos: todo list;
  tags: string list;
} 

type todo = {
  title: string;
  completed: bool;
}
*)

(* OPs
  Create note
  Update note body
  Update todo item name of note
  Update todo item item completeness of note
  Delete todo item item of note
  Delete note
*)

type note = {
    id: string;
    body: string;
    likes: string list;
    dislikes: string list;
    sourceIp: string;
    edits: int;
    lastEdit: int; (* Date since epoch in ms *)
} [@@deriving yojson]

type json_get_note_request = {
  sourceIp: string;
} [@@deriving yojson]

type json_get_note_response = {
  id: string;
  body: string;
  userVote: int;
  voteCount: int;
  isUser: bool;
  edited: bool;
  lastEdit: int;
} [@@deriving yojson]

type json_post_note_request = {
  body: string;
  sourceIp: string;
} [@@deriving yojson]

type json_put_vote_request = {
  like: bool;
  noteId: string;
  sourceIp: string;
} [@@deriving yojson]

type json_patch_edit_body_request = {
  body: string;
  noteId: string;
  sourceIp: string;
} [@@deriving yojson]

type json_delete_note_request = {
  noteId : string;
  sourceIp: string;
} [@@deriving yojson]

let create_note_id () = Printf.sprintf ("%d_%d") (Int.of_float (Unix.time ())) (Random.int 1_000_000)

(* let rec list_take n lst =
  match lst with
  | [] -> []
  | _ when n <= 0 -> []
  | x :: xs -> x :: take (n - 1) xs *)

let read_notes () = 
  let json_db = 
    try
      Yojson.Safe.from_file "db.json" 
    with
    | _ -> `Assoc [("notes", `List [])]
  in

  match json_db |> member "notes" with
  | `Null -> []
  | `List notes_json -> List.map note_of_yojson notes_json
  | _ -> failwith "Invalid JSON format for notes list"

let get_notes sourceIp (notes: note list) : json_get_note_response list =
  let rec aux acc (ns: note list) =
    match ns with
    | [] -> List.rev acc
    | x :: xs ->
        let isUser = ((=) x.sourceIp sourceIp) in
        let updated_note = {
          id = x.id;
          body = x.body;
          isUser = isUser;
          userVote = if List.exists ((=) sourceIp) x.likes then 1 else if List.exists ((=) sourceIp) x.dislikes then -1 else 0;
          voteCount = (List.length x.likes) - (List.length x.dislikes);
          edited = x.edits > 0;
          lastEdit = x.lastEdit
        } in
        aux (updated_note :: acc) xs
  in
  aux [] notes
  
let mutex = Mutex.create ()
let cached_notes : note list ref = ref []

let process_notes sourceIp =
  get_notes sourceIp !cached_notes

let initialize_cache () =
  cached_notes := read_notes ()

let save_cache_to_disk () =
  Mutex.lock mutex;
  print_endline "Saving data cache to JSON DB";

  `Assoc [("notes", `List (List.map yojson_of_note !cached_notes))]
  |> Yojson.Safe.to_file "db.json";

  Mutex.unlock mutex

let handle_exit_signal signal =
  print_endline ("Caught signal: " ^ string_of_int signal);
  save_cache_to_disk ();
  exit 0
  
let rec periodic_cache_save interval_seconds =
  Lwt.bind (Lwt_unix.sleep interval_seconds)
    (fun () ->
      save_cache_to_disk ();
      periodic_cache_save interval_seconds)
  
let () =
  initialize_cache ();

  Sys.set_signal Sys.sigint (Sys.Signal_handle handle_exit_signal);
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle_exit_signal);
  let _ = periodic_cache_save 300.0 in  

  Dream.run ~interface:"127.0.0.1" ~port:7050
  @@ Dream.logger
  @@ Dream.origin_referrer_check
  @@ Dream.router [
    Dream.get "/notes" 
    (fun request -> 
      let%lwt body = Dream.body request in

      let sourceIp =
        (body
        |> Yojson.Safe.from_string
        |> json_get_note_request_of_yojson).sourceIp
      in

      let notes = process_notes sourceIp in
      let sorted_notes = 
        List.sort (fun a b -> compare b.voteCount a.voteCount) notes
      in
      `Assoc [("notes", `List (List.map (fun note -> 
        `Assoc [
          ("id", `String note.id);
          ("body", `String note.body);
          ("voteCount", `Int note.voteCount);
          ("userVote", `Int note.userVote);
          ("isUser", `Bool note.isUser);
          ("edited", `Bool note.edited);
          ("lastEdit", `Int note.lastEdit);
        ]) sorted_notes))]  
      |> Yojson.Safe.to_string
      |> Dream.json
    );

    Dream.post "/notes"
      (fun request ->
        Mutex.lock mutex;
        let handle_request () =
          let%lwt body = Dream.body request in

          let post_note_object =
            body
            |> Yojson.Safe.from_string
            |> json_post_note_request_of_yojson
          in

          let note_id = create_note_id () in

          let new_note = `Assoc[
            ("id", `String note_id);
            ("body", `String (String.sub post_note_object.body 0 (min (String.length post_note_object.body) 280))); 
            ("likes", `List []);
            ("dislikes", `List []);
            ("sourceIp", `String post_note_object.sourceIp);
            ("edits", `Int 0);
            ("lastEdit", `Int (int_of_float ((Unix.time ()) *. 1000.0)));
          ] in

          (* let all_notes = new_note :: read_notes () in
          let trimmed_notes = 
            match all_notes with
            | [] -> []
            | _ -> all_notes |> take 30 
          in *)

          cached_notes := (new_note |> note_of_yojson) :: !cached_notes;
          
          `Assoc[
            ("body", new_note |> member "body"); 
            ("id", new_note |> member "id")
          ]
          |> Yojson.Safe.to_string
          |> Dream.json
        in
  
        Lwt.finalize handle_request (fun () ->
          Mutex.unlock mutex;
          Lwt.return_unit
        )
      );

      Dream.put "/notes/vote"
        (fun request ->
          Mutex.lock mutex;
          let handle_request () =
            let%lwt body = Dream.body request in

            let post_vote_object =
              body
              |> Yojson.Safe.from_string
              |> json_put_vote_request_of_yojson
            in

            let all_notes = !cached_notes in

            let updated_notes = 
              List.map (fun (note: note) ->
                if note.id = post_vote_object.noteId then
                  let already_liked = List.exists ((=) post_vote_object.sourceIp) note.likes in
                  let already_disliked = List.exists ((=) post_vote_object.sourceIp) note.dislikes in
            
                  let updated_likes, updated_dislikes =
                    match post_vote_object.like, already_liked, already_disliked with
                    | true, true, _ -> 
                      (* Already liked, remove the like *)
                      List.filter ((<>) post_vote_object.sourceIp) note.likes, note.dislikes
                    | false, _, true -> 
                      (* Already disliked, remove the dislike *)
                      note.likes, List.filter ((<>) post_vote_object.sourceIp) note.dislikes
                    | true, false, _ -> 
                      (* No like, add the like *)
                      post_vote_object.sourceIp :: note.likes, List.filter ((<>) post_vote_object.sourceIp) note.dislikes
                    | false, _, false -> 
                      (* No dislike, add the dislike *)
                      List.filter ((<>) post_vote_object.sourceIp) note.likes, post_vote_object.sourceIp :: note.dislikes
                  in
                  { note with likes = updated_likes; dislikes = updated_dislikes }
                else
                  note
              ) all_notes
            in

            cached_notes := updated_notes;
            
            `String "Vote recorded"
            |> Yojson.Safe.to_string
            |> Dream.respond
          in

          Lwt.finalize handle_request (fun () ->
            Mutex.unlock mutex;
            Lwt.return_unit
          )
        );

        Dream.patch "/notes/edit/body"
        (fun request ->
          Mutex.lock mutex;
          let handle_request () =
            let%lwt body = Dream.body request in

            let patch_edit_body_object =
              body
              |> Yojson.Safe.from_string
              |> json_patch_edit_body_request_of_yojson
            in

            let all_notes = !cached_notes in

            let updated_notes = 
              List.map (fun (note: note) ->
                if note.id = patch_edit_body_object.noteId && note.sourceIp = patch_edit_body_object.sourceIp then
                  { note with 
                  body = patch_edit_body_object.body;
                  edits = note.edits + 1;
                  lastEdit = int_of_float (Unix.time () *. 1000.0); }
                else
                  note
              ) all_notes
            in

            cached_notes := updated_notes;
            
            `String "Note edited"
            |> Yojson.Safe.to_string
            |> Dream.respond
          in

          Lwt.finalize handle_request (fun () ->
            Mutex.unlock mutex;
            Lwt.return_unit
          )
        );

      Dream.delete "/notes"
      (fun request ->
        Mutex.lock mutex;
        let handle_request () =
          let%lwt body = Dream.body request in

          let delete_note_object =
            body
            |> Yojson.Safe.from_string
            |> json_delete_note_request_of_yojson
          in

          let all_notes = !cached_notes in

          let undeleted_notes = 
            List.filter (fun (note: note) ->
              not ((=) note.id delete_note_object.noteId) && ((=) note.sourceIp delete_note_object.sourceIp)
            ) all_notes
          in

          cached_notes := undeleted_notes;
          
          "HTTP/1.1 200 OK"
          |> Dream.respond
        in

        Lwt.finalize handle_request (fun () ->
          Mutex.unlock mutex;
          Lwt.return_unit
        )
      );
  ]