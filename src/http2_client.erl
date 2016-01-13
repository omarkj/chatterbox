-module(http2_client).

-behaviour(gen_fsm).

-include("http2.hrl").

-export([start_link/1]).

-export([send_request/4,
	 google/1]).

-export([frame/2]).

-export([init/1,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 code_change/4,
	 terminate/3]).

-export([waiting_for_server_settings/2,
	 waiting_for_server_ack/2,
	 connected/2]).

-record(state, {
	  conn,
	  client_settings,
	  server_settings,
	  ack = false :: boolean(),
	  ping_freq :: non_neg_integer()|undefined,
	  streams = dict:new() :: dict:dict()
	 }).

-type option() :: {host, string()} |
		  {port, non_neg_integer()} |
		  {ssl, boolean()} |
		  {ssl_opts, list()}.

-spec start_link([option()]) ->
                        {ok, pid()} |
                        ignore |
                        {error, term()}.
start_link(Options) ->
    gen_fsm:start_link(?MODULE, [Options], []).

frame(Pid, Frame) ->
    gen_fsm:send_event(Pid, {frame, Frame}).

google(Pid) ->
    send_request(Pid, [{<<":path">>, <<"/">>}], <<>>, []).

send_request(Pid, Headers, Body, Options) ->
    gen_fsm:send_event(Pid, {send_request, Headers, Body, Options}).

init([Options]) ->
    case http2_conn:start_link(Options++[{client, self()}]) of
	{ok, Pid} ->
	    http2_conn:send_presamble(Pid),
	    Raw = http2_frame_settings:get_frame(#settings{}, #settings{}),
	    CS = #connection_state{socket=Pid,
				   next_available_stream_id=1},
	    send_raw(Raw, CS),
	    {ok, waiting_for_server_settings,
	     #state{conn=CS, client_settings=#settings{},
		    ping_freq=proplists:get_value(ping_freq, Options)}};
	Error ->
	    Error
    end.

waiting_for_server_settings({frame, {#frame_header{type=?SETTINGS},
				     ServerSettings}}, State) ->
    % Maybe set a timer and wait for the ack. If it does not come in time,
    % shutdown?
    {next_state, waiting_for_server_ack,
     State#state{server_settings=ServerSettings}}.

waiting_for_server_ack({frame, {#frame_header{type=?SETTINGS}=FrameHeader,
			        _}}, State) ->
    Ack = ?IS_FLAG(FrameHeader#frame_header.flags, ?FLAG_ACK),
    maybe_append_ping({next_state, connected, State#state{ack=Ack}}).

connected({send_request, Headers, Body, Options}, #state{conn=CS}=State) ->
    {FramedHeaders, CS1} = frame_headers(Headers, Options, CS),
    FramedBody = frame_body(Body, CS1),
    send_frames([FramedHeaders|FramedBody], CS),
    maybe_append_ping({next_state, connected,
		       increment_nasi(State#state{conn=CS})});
connected(timeout, #state{conn=CS}=State) ->
    % Send a PING frame
    FramedPing = frame_ping(os:system_time(milli_seconds)),
    send_frames(FramedPing, CS),
    maybe_append_ping({next_state, connected, State});
connected({frame, {#frame_header{type=?PING}, #ping{opaque_data=Ping}}},
	  State) ->
    Now = os:system_time(milli_seconds),
    <<PingSentAt:64>> = Ping,
    lager:debug("Latency to upstream ~p", [Now - PingSentAt]),
    maybe_append_ping({next_state, connected, State});
connected({frame, {#frame_header{type=?GOAWAY}, _}}, State) ->
    {stop, normal, State};
connected({frame, {_FrameHeader, _Payload}=Frame}, State) ->
    lager:debug("Unhandled frame: ~p", [Frame]),
    maybe_append_ping({next_state, connected, State});
connected(_Event, State) ->
    maybe_append_ping({next_state, connected, State}).

handle_event(_Event, FsmState, State) ->
    maybe_append_ping({next_state, FsmState, State}).

handle_sync_event(_Event, _From, FsmState, State) ->
    maybe_append_ping({next_state, FsmState, State}).

handle_info(_, FsmState, State) ->
    maybe_append_ping({next_state, FsmState, State}).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(normal, _StateName, _State) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    lager:debug("terminate reason: ~p~n", [_Reason]).

%% Internal
maybe_append_ping({Cmd, FsmState, #state{ping_freq=undefined}=State}) ->
    {Cmd, FsmState, State};
maybe_append_ping({Cmd, connected, #state{ping_freq=PF}=State}) ->
    {Cmd, connected, State, PF};
maybe_append_ping({Cmd, FsmState, State}) ->
    {Cmd, FsmState, State}.

increment_nasi(#state{conn=#connection_state{next_available_stream_id=NASI}=CS}=State) ->
    State#state{conn=CS#connection_state{next_available_stream_id=NASI+2}}.

send_frames(Frame, #connection_state{socket=Pid}) ->
    http2_conn:send_frames(Pid, Frame).

send_raw(Raw, #connection_state{socket=Pid}) ->
    http2_conn:send_raw(Pid, Raw).

frame_ping(PV) ->
    http2_frame_ping:to_frame(<<PV:64>>).

frame_headers(Headers, Options,
	      #connection_state{encode_context=EC,
				next_available_stream_id=NASI}=CS) ->
    case proplists:get_value(matcher, Options) of
	undefined ->
	    {HeaderFrame, EC1} = http2_frame_headers:to_frame(NASI, Headers,
							      EC),
	    {HeaderFrame, CS#connection_state{encode_context=EC1}};
	Matcher ->
	    {HeaderFrame, EC1} = http2_frame_headers:to_frame(NASI, Headers,
							      Matcher, EC),
	    {HeaderFrame, CS#connection_state{encode_context=EC1}}
end.

frame_body(Body, #connection_state{send_settings=SS,
				  next_available_stream_id=NASI}) ->
    http2_frame_data:to_frames(NASI, Body, SS).
