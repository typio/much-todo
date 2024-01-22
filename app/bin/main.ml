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
    source_ip: string;
} [@@deriving yojson]

type json_get_note_request = {
  source_ip: string;
} [@@deriving yojson]

type json_get_note_response = {
  id: string;
  body: string;
  userVote: int;
  voteCount: int;
  isUser: bool;
} [@@deriving yojson]

type json_post_note_request = {
  body: string;
  source_ip: string;
} [@@deriving yojson]

type json_post_vote_request = {
  like: bool;
  noteId: string;
  source_ip: string;
} [@@deriving yojson]

type json_delete_note_request = {
  noteId : string;
  source_ip: string;
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

let get_notes source_ip (notes: note list) : json_get_note_response list =
  let rec aux acc (ns: note list) =
    match ns with
    | [] -> List.rev acc
    | x :: xs ->
        let isUser = ((=) x.source_ip source_ip) in
        let updated_note = {
          id = x.id;
          body = x.body;
          isUser = isUser;
          userVote = if List.exists ((=) source_ip) x.likes then 1 else if List.exists ((=) source_ip) x.dislikes then -1 else 0;
          voteCount = (List.length x.likes) - (List.length x.dislikes)
        } in
        aux (updated_note :: acc) xs
  in
  aux [] notes
  
  
let process_notes source_ip =
  let notes = read_notes () in
  get_notes source_ip notes
  
let mutex = Mutex.create ()

let () =
  Dream.run ~interface:"127.0.0.1" ~port:7050
  @@ Dream.logger
  @@ Dream.origin_referrer_check
  @@ Dream.router [
    Dream.get "/" 
    (fun request -> 
      let%lwt body = Dream.body request in

      let source_ip =
        (body
        |> Yojson.Safe.from_string
        |> json_get_note_request_of_yojson).source_ip
      in

      let notes = process_notes source_ip in
      `Assoc [("notes", `List (List.map (fun note -> 
        `Assoc [
          ("id", `String note.id);
          ("body", `String note.body);
          ("voteCount", `Int note.voteCount);
          ("userVote", `Int note.userVote);
          ("isUser", `Bool note.isUser);
        ]) notes))]  
      |> Yojson.Safe.to_string
      |> Dream.json
    );

    Dream.post "/"
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
            ("body", `String (String.sub post_note_object.body 0 (min (String.length post_note_object.body) 280))); 
            ("id", `String note_id);
            ("source_ip", `String post_note_object.source_ip);
            ("likes", `List []);
            ("dislikes", `List []);
          ] in

          (* let all_notes = new_note :: read_notes () in
          let trimmed_notes = 
            match all_notes with
            | [] -> []
            | _ -> all_notes |> take 30 
          in *)
          let all_notes = new_note :: (read_notes () |> List.map yojson_of_note) in
          
          `Assoc [("notes", `List all_notes)] 
          |> Yojson.Safe.to_file "db.json";
          
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

      Dream.post "/vote"
        (fun request ->
          Mutex.lock mutex;
          let handle_request () =
            let%lwt body = Dream.body request in

            let post_vote_object =
              body
              |> Yojson.Safe.from_string
              |> json_post_vote_request_of_yojson
            in

            let all_notes = read_notes () in

            let updated_notes = 
              List.map (fun (note: note) ->
                if note.id = post_vote_object.noteId then
                  let already_liked = List.exists ((=) post_vote_object.source_ip) note.likes in
                  let already_disliked = List.exists ((=) post_vote_object.source_ip) note.dislikes in
            
                  let updated_likes, updated_dislikes =
                    match post_vote_object.like, already_liked, already_disliked with
                    | true, true, _ -> 
                      (* Already liked, remove the like *)
                      List.filter ((<>) post_vote_object.source_ip) note.likes, note.dislikes
                    | false, _, true -> 
                      (* Already disliked, remove the dislike *)
                      note.likes, List.filter ((<>) post_vote_object.source_ip) note.dislikes
                    | true, false, _ -> 
                      (* No like, add the like *)
                      post_vote_object.source_ip :: note.likes, List.filter ((<>) post_vote_object.source_ip) note.dislikes
                    | false, _, false -> 
                      (* No dislike, add the dislike *)
                      List.filter ((<>) post_vote_object.source_ip) note.likes, post_vote_object.source_ip :: note.dislikes
                  in
                  { note with likes = updated_likes; dislikes = updated_dislikes }
                else
                  note
              ) all_notes
            in

            `Assoc [("notes", `List (List.map yojson_of_note updated_notes))] 
            |> Yojson.Safe.to_file "db.json";
            
            `String "Vote recorded"
            |> Yojson.Safe.to_string
            |> Dream.respond
          in

          Lwt.finalize handle_request (fun () ->
            Mutex.unlock mutex;
            Lwt.return_unit
          )
        );
        
      Dream.delete "/"
      (fun request ->
        Mutex.lock mutex;
        let handle_request () =
          let%lwt body = Dream.body request in

          let delete_note_object =
            body
            |> Yojson.Safe.from_string
            |> json_delete_note_request_of_yojson
          in

          let all_notes = read_notes () in

          let undeleted_notes = 
            List.filter (fun (note: note) ->
              not ((=) note.id delete_note_object.noteId) && ((=) note.source_ip delete_note_object.source_ip)
            ) all_notes
          in
                    
          `Assoc [("notes", `List (List.map yojson_of_note undeleted_notes))] 
          |> Yojson.Safe.to_file "db.json";
          
          "HTTP/1.1 200 OK"
          |> Dream.respond
        in

        Lwt.finalize handle_request (fun () ->
          Mutex.unlock mutex;
          Lwt.return_unit
        )
      );
  ]