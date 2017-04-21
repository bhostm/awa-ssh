(*
 * Copyright (c) 2017 Christiano F. Haesbaert <haesbaert@haesbaert.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Util

let put_uint8 = Dbuf.put_uint8

let put_bool b t =
  let x = if b then 1 else 0 in
  Dbuf.put_uint8 x t

let put_uint32 = Dbuf.put_uint32_be

let put_string s t =
  let len = String.length s in
  let t = put_uint32 (Int32.of_int len) t in
  let t = Dbuf.guard_space len t in
  Cstruct.blit_from_string s 0 t.Dbuf.cbuf t.Dbuf.coff len;
  Dbuf.shift len t

let put_cstring s t =
  let len = Cstruct.len s in
  let t = put_uint32 (Int32.of_int len) t in
  let t = Dbuf.guard_space len t in
  Cstruct.blit s 0 t.Dbuf.cbuf t.Dbuf.coff len;
  Dbuf.shift len t

let put_id id buf =
  put_uint8 (Ssh.message_id_to_int id) buf

let put_raw buf t =
  let len = Cstruct.len buf in
  let t = Dbuf.guard_space len t in
  Cstruct.blit buf 0 t.Dbuf.cbuf t.Dbuf.coff len;
  Dbuf.shift len t

let put_random len t =
  put_raw (Nocrypto.Rng.generate len) t

let put_nl nl t =
  put_string (String.concat "," nl) t

let put_mpint mpint t =
  let mpbuf = Nocrypto.Numeric.Z.to_cstruct_be mpint in
  let mplen = Cstruct.len mpbuf in
  let t =
    if mplen > 0 &&
       ((Cstruct.get_uint8 mpbuf 0) land 0x80) <> 0 then
      put_uint32 (Int32.of_int (succ mplen)) t |>
      put_uint8 0
    else
      put_uint32 (Int32.of_int mplen) t
  in
  put_raw mpbuf t

let put_kexinit kex t =
  let open Ssh in
  let nll = [ kex.kex_algs;
              kex.server_host_key_algs;
              kex.encryption_algs_ctos;
              kex.encryption_algs_stoc;
              kex.mac_algs_ctos;
              kex.mac_algs_stoc;
              kex.compression_algs_ctos;
              kex.compression_algs_stoc;
              kex.languages_ctos;
              kex.languages_stoc; ]
  in
  let t = put_raw kex.cookie t in
  List.fold_left (fun buf nl -> put_nl nl buf) t nll |>
  put_bool kex.first_kex_packet_follows |>
  put_uint32 Int32.zero

let blob_of_kexinit kex =
  put_id Ssh.SSH_MSG_KEXINIT (Dbuf.create ()) |>
  put_kexinit kex |> Dbuf.to_cstruct

let blob_of_pubkey = function
  | Hostkey.Rsa_pub rsa ->
    let open Nocrypto.Rsa in
    put_string "ssh-rsa" (Dbuf.create ()) |>
    put_mpint rsa.e |>
    put_mpint rsa.n |>
    Dbuf.to_cstruct
  | Hostkey.Unknown -> invalid_arg "Can't make blob of unknown key."

let blob_of_signature name signature =
  put_string name (Dbuf.create ()) |>
  put_cstring signature |>
  Dbuf.to_cstruct

let base64_of_pubkey pub =
  B64.encode (blob_of_pubkey pub |> Cstruct.to_string)

let authfmt_of_pubkey pub =
  Printf.sprintf "%s %s" (Hostkey.sshname pub) (base64_of_pubkey pub)

let put_pubkey pubkey t =
  put_cstring (blob_of_pubkey pubkey) t

let put_message msg buf =
  let open Ssh in
  let unimplemented () = failwith "implement me" in
  let guard p e = if not p then invalid_arg e in
  match msg with
    | Ssh_msg_disconnect (code, desc, lang) ->
      put_id SSH_MSG_DISCONNECT buf |>
      put_uint32 (disconnect_code_to_int code) |>
      put_string desc |>
      put_string lang
    | Ssh_msg_ignore s ->
      put_id SSH_MSG_IGNORE buf |>
      put_string s
    | Ssh_msg_unimplemented x ->
      put_id SSH_MSG_UNIMPLEMENTED buf |>
      put_uint32 x
    | Ssh_msg_debug (always_display, message, lang) ->
      put_id SSH_MSG_DEBUG buf |>
      put_bool always_display |>
      put_string message |>
      put_string lang
    | Ssh_msg_service_request s ->
      put_id SSH_MSG_SERVICE_REQUEST buf |>
      put_string s
    | Ssh_msg_service_accept s ->
      put_id SSH_MSG_SERVICE_ACCEPT buf |>
      put_string s
    | Ssh_msg_kexinit kex ->
      put_id SSH_MSG_KEXINIT buf |>
      put_kexinit kex
    | Ssh_msg_newkeys ->
      put_id SSH_MSG_NEWKEYS buf
    | Ssh_msg_kexdh_init e ->
      put_id SSH_MSG_KEXDH_INIT buf |>
      put_mpint e
    | Ssh_msg_kexdh_reply (k_s, f, signature) ->
      put_id SSH_MSG_KEXDH_REPLY buf |>
      put_pubkey k_s |>
      put_mpint f |>
      put_cstring (blob_of_signature (Hostkey.sshname k_s) signature)
    | Ssh_msg_userauth_request (user, service, auth_method) ->
      let buf = put_id SSH_MSG_USERAUTH_REQUEST buf |>
                put_string user |>
                put_string service
      in
      (match auth_method with
       | Publickey (key_alg, pubkey, signature) ->
         let buf = put_string "publickey" buf |>
                   put_bool (is_some signature) |>
                   put_string key_alg |>
                   put_pubkey pubkey
         in
         (match signature with
          | None -> buf
          | Some signature -> put_cstring signature buf)
       | Password (password, oldpassword) ->
         let buf = put_string "password" buf in
         (match oldpassword with
          | None ->
            put_bool false buf |>
            put_string password
          | Some oldpassword ->
            put_bool true buf |>
            put_string oldpassword |>
            put_string password)
       | Hostbased (key_alg, key_blob, hostname, hostuser, hostsig) ->
         put_string "hostbased" buf |>
         put_string key_alg |>
         put_cstring key_blob |>
         put_string hostname |>
         put_string hostuser |>
         put_cstring hostsig
       | Authnone -> put_string "none" buf)
    | Ssh_msg_userauth_failure (nl, psucc) ->
      put_id SSH_MSG_USERAUTH_FAILURE buf |>
      put_nl nl |>
      put_bool psucc
    | Ssh_msg_userauth_success ->
      put_id SSH_MSG_USERAUTH_SUCCESS buf
    | Ssh_msg_userauth_banner (message, lang) ->
      put_id SSH_MSG_USERAUTH_BANNER buf |>
      put_string message |>
      put_string lang
    | Ssh_msg_userauth_pk_ok pubkey ->
      guard (pubkey <> Hostkey.Unknown) "Unknown key";
      put_id SSH_MSG_USERAUTH_PK_OK buf |>
      put_string (Hostkey.sshname pubkey) |>
      put_pubkey pubkey
    | Ssh_msg_global_request -> unimplemented ()
    | Ssh_msg_request_success -> unimplemented ()
    | Ssh_msg_request_failure ->
      put_id SSH_MSG_REQUEST_FAILURE buf
    | Ssh_msg_channel_open -> unimplemented ()
    | Ssh_msg_channel_open_confirmation -> unimplemented ()
    | Ssh_msg_channel_open_failure ->
      put_id SSH_MSG_CHANNEL_OPEN_FAILURE buf
    | Ssh_msg_channel_window_adjust (channel, n) ->
      put_id SSH_MSG_CHANNEL_WINDOW_ADJUST buf |>
      put_uint32 channel |>
      put_uint32 n
    | Ssh_msg_channel_data -> unimplemented ()
    | Ssh_msg_channel_extended_data -> unimplemented ()
    | Ssh_msg_channel_eof channel ->
      put_id SSH_MSG_CHANNEL_EOF buf |>
      put_uint32 channel
    | Ssh_msg_channel_close channel ->
      put_id SSH_MSG_CHANNEL_CLOSE buf |>
      put_uint32 channel
    | Ssh_msg_channel_request -> unimplemented ()
    | Ssh_msg_channel_success channel ->
      put_id SSH_MSG_CHANNEL_SUCCESS buf |>
      put_uint32 channel
    | Ssh_msg_channel_failure channel ->
      put_id SSH_MSG_CHANNEL_FAILURE buf |>
      put_uint32 channel
    | Ssh_msg_version version ->  (* Mocked up version message *)
      put_raw (Cstruct.of_string (version ^ "\r\n")) buf
