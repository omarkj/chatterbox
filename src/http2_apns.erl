-module(http2_apns).

-export([open_connection/0,
	 send_notification_1/1,
	 send_notification_2/1]).

open_connection() ->
    {ok, CertFile} = file:read_file(os:getenv("CERT_PATH")),
    [{_, Cert, _}, {Tag, DerEncodedPk, _}] = public_key:pem_decode(CertFile),
    Key = {Tag, DerEncodedPk},
    http2_client:start_link([{host, "api.push.apple.com"}, {port, 443}, {ssl, true}, {ssl_opts, [{key, Key}, {cert, Cert}]}]).

send_notification_1(Pid) ->
    UUID = <<"b284fa88-b986-11e5-9912-ba0be0483c18">>,
    send_notificaiton(Pid, indexer_fun_1(), UUID).

send_notification_2(Pid) ->
    UUID = <<"b284fe34-b986-11e5-9912-ba0be0483c18">>,
    send_notificaiton(Pid, indexer_fun_2(), UUID).

send_notificaiton(Pid, Fun, UUID) ->
    Body = <<"{\"aps\":{\"url-args\":[\"urlarg\"],\"alert\":{\"message\":\"Body\"}}}">>,
    Headers = [{<<":method">>,<<"POST">>},
	       {<<":path">>,
		<<"/3/device/D70A50C657EDDC0ED3CC8D1347A4F6DACE972B70CCABDB9728F22380AFE04455">>},
	       {<<"apns-id">>, UUID},
	       {<<"apns-expiration">>,<<"0">>},
	       {<<"apns-priority">>,<<"10">>},
	       {<<"content-length">>,<<"58">>}],
    http2_client:send_request(Pid, Headers, Body, [{matcher, Fun}]).
    

indexer_fun_1() ->
    fun({<<":path">>, _}, _)           -> {literal_wo_indexing, undefined};
       (Pair, T)                       -> hpack_index:match(Pair, T)
    end.

indexer_fun_2() ->
    fun({<<":path">>, _}, _)           -> {literal_wo_indexing, undefined};
       ({<<"apns_id">>, _}, _)         -> {literal_wo_indexing, undefined};
       ({<<"apns-expiration">>, _}, _) -> {literal_wo_indexing, undefined};
       (Pair, T)                       -> hpack_index:match(Pair, T)
    end.
