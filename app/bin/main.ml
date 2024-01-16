open Ppx_yojson_conv_lib.Yojson_conv.Primitives
open Yojson.Safe.Util

(* 
type note = {
  id: string;
  title: string;
  body: string;
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
   Update note name
   Add item to note
   Update item name of note
   Update item completeness of note
   Delete item of note
   Delete note
*)

type message_object = {
  message : string;
} [@@deriving yojson]

type message_id_object = {
  messageId : string;
} [@@deriving yojson]

let get_id_from_message msg =
  match msg with
  | `Assoc kv_list -> (
      match List.assoc_opt "id" kv_list with
      | Some (`String id) -> Some id
      | _ -> None
    )
  | _ -> None


(* type create_note_object = {
  title : string;
} [@@deriving yojson] *)

let mutex = Mutex.create ()

let read_messages () = 
  let json_db = 
    try
      Yojson.Safe.from_file "db.json" 
    with
    | _ -> `Assoc [("messages", `List [])]
  in

  match json_db |> member "messages" with
  | `Null -> []
  | msgs -> msgs |> to_list

let rec take n lst =
  match lst with
  | [] -> []
  | _ when n <= 0 -> []
  | x :: xs -> x :: take (n - 1) xs
  
let () =
  Dream.run ~interface:"127.0.0.1" ~port:7050
  @@ Dream.logger
  @@ Dream.origin_referrer_check
  @@ Dream.router [
    Dream.get "/" 
    (fun _ -> 
      `Assoc [("messages", `List (read_messages ()) )]  
      |> Yojson.Safe.to_string
      |> Dream.json
    );
    Dream.post "/"
      (fun request ->
        Mutex.lock mutex;
        let handle_request () =
          let%lwt body = Dream.body request in

          let message_object =
            body
            |> Yojson.Safe.from_string
            |> message_object_of_yojson
          in

          let message_id = 
            Printf.sprintf ("%d_%d") (Int.of_float (Unix.time ())) (Random.int 1_000_000)
          in

          let new_message = `Assoc[
            ("body", `String (String.sub message_object.message 0 (min (String.length message_object.message) 280))); 
            ("id", `String message_id)
          ] in
          
          let all_messages = new_message :: read_messages () in
          let trimmed_messages = 
            match all_messages with
            | [] -> []
            | _ -> all_messages |> take 30 
          in
          
          `Assoc [("messages", `List trimmed_messages)] 
          |> Yojson.Safe.to_file "db.json";
          
          new_message
          |> Yojson.Safe.to_string
          |> Dream.json
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

          let message_id_object =
            body
            |> Yojson.Safe.from_string
            |> message_id_object_of_yojson
          in

          let message_id = message_id_object.messageId in 

          let all_messages = read_messages () in

          let filtered_messages = 
            List.filter (fun msg ->
              match get_id_from_message msg with
              | Some id -> (
                match String.compare id message_id with
                | 0 ->  print_endline message_id; false
                | _ -> print_endline message_id; true
              )
              | None -> true
            ) all_messages
          in
                    
          `Assoc [("messages", `List filtered_messages)] 
          |> Yojson.Safe.to_file "db.json";
          
          "HTTP/1.1 200 OK"
          |> Dream.respond
        in
  
        Lwt.finalize handle_request (fun () ->
          Mutex.unlock mutex;
          Lwt.return_unit
        )
      );
      Dream.post "/create_note"
      (fun _ ->
        print_endline("create_note post");
        Dream.empty `Bad_Request
      ) 
  ]