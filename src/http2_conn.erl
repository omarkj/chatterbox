-module(http2_conn).

% A process that handles a connection to a HTTP2 server.

-behaviour(gen_server).
-include("http2.hrl").

-export([start_link/1,
	 send_presamble/1,
	 send_frames/2,
	 send_raw/2]).

-export([init/1,
	 handle_cast/2,
	 handle_call/3,
	 handle_info/2,
	 code_change/3,
	 terminate/2]).

-record(parser, {
	  wfh = undefined
	 }).

-record(state, {
	  socket,
	  transport,
	  parser = #parser{},
	  client
	 }).

-spec start_link(list()) -> {ok, pid()}.
start_link(Options) ->
    gen_server:start_link(?MODULE, [Options], []).

-spec send_frames(pid(), [frame()]) -> ok.
send_frames(Pid, Frames) ->
    gen_server:cast(Pid, {send_frames, Frames}).

-spec send_presamble(pid()) -> ok.
send_presamble(Pid) ->
    send_raw(Pid, <<?PREAMBLE>>).

-spec send_raw(pid(), iolist()) -> ok.
send_raw(Pid, Data) ->
    gen_server:cast(Pid, {send_raw, Data}).

init([Options]) ->
    Host = proplists:get_value(host, Options),
    Port = proplists:get_value(port, Options),
    Client = proplists:get_value(client, Options),
    {Transport, ClientOptions} = client_options_(Options),
    case Transport:connect(Host, Port, ClientOptions) of
	{ok, Socket} ->
	    {ok, #state{socket=Socket, transport=Transport, client=Client}};
	{error, timeout} ->
	    {error, timeout};
	Error ->
	    Error
    end.

handle_cast({send_frames, Frames}, State) ->
    send_frames_(Frames, State),
    recv(),
    {noreply, State};
handle_cast({send_raw, Data}, State) ->
    send_raw_(Data, State),
    recv(),
    {noreply, State};
handle_cast(recv, State) ->
    case fetch_data(State) of
	{ok, State1} ->
	    recv(),
	    {noreply, State1};
	{ok, Frame, State1} ->
	    notify_client(Frame, State1),
	    {noreply, State1};
	{error, closed} ->
	    {stop, normal, State}
    end;
handle_cast(_Cast, State) ->
    {noreply, State}.

handle_call(_Call, _From, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% Internal
notify_client(Frame, #state{client=Client}) ->
    http2_client:frame(Client, Frame).

fetch_data(#state{parser=Parser}=State) ->
    fetch_data(Parser, State).

fetch_data(#parser{wfh=undefined}=Parser, State) ->
    % No frame header being worked on. Go fetch a header.
    recv_(9, fun handle_header/3, Parser, State);
fetch_data(#parser{wfh=#frame_header{length=Length}}=Parser, State) ->
    % Fetch payload data associated with a header
    recv_(Length, fun handle_payload/3, Parser, State).

handle_header(HeaderBin, Parser, State) ->
    {Header1, <<>>} = http2_frame:read_binary_frame_header(HeaderBin),
    Parser1 = Parser#parser{wfh=Header1},
    {ok, State#state{parser=Parser1}}.

handle_payload(PayloadBin, #parser{wfh=Header}, State) ->
    {ok, Payload, <<>>} = http2_frame:read_binary_payload(PayloadBin, Header),
    {ok, {Header, Payload}, State#state{parser=#parser{}}}.

handle_error({error, timeout}, Parser, State) ->
    {ok, State#state{parser=Parser}};
handle_error({error, closed}, _, _) ->
    {error, closed}.

recv_(0, HandleFun, Parser, State) ->
    HandleFun(<<>>, Parser, State);
recv_(Length, HandleFun, Parser,
      #state{socket=Socket, transport=Transport}=State) ->
    case Transport:recv(Socket, Length, 1) of
	{ok, Data} ->
	    HandleFun(Data, Parser, State);
	E ->
	    handle_error(E, Parser, State)
    end.

recv() ->
    gen_server:cast(self(), recv).

send_frames_(Frames, State) ->
    [send_raw_(http2_frame:to_binary(F), State) || F <- Frames].

send_raw_(Data, #state{socket=Socket, transport=Transport}) ->
    lager:debug("Sending ~p", [Data]),
    Transport:send(Socket, Data).

client_options_(Options) ->
    ClientOptions = [binary, {packet, raw}, {active, false}],
    case proplists:get_value(ssl, Options, false) of
	false -> {gen_tcp, ClientOptions};
	true ->
	    SSLOptions = proplists:get_value(ssl_opts, Options, []),
	    {ssl, ClientOptions ++ SSLOptions ++
		 [{client_preferred_next_protocols, {client, [<<"h2">>]}}]}
    end.
