-module(settings_handshake_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [times_out_on_no_ack_of_server_settings,
     protocol_error_on_never_send_client_settings].

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.


%% This test does not use the http2c client because it needs to
%% circumvent a behavior that the http2c takes for granted.

%% This is an optional behavior as per section 6.5 of the HTTP/2 RFC
%% 7540
%% If the sender of a SETTINGS frame does not receive an
%% acknowledgement within a reasonable amount of time, it MAY issue a
%% connection error (Section 5.4.1) of type SETTINGS_TIMEOUT.
times_out_on_no_ack_of_server_settings(Config) ->
    chatterbox_test_buddy:start([{ssl, true}|Config]),

    {ok, Port} = application:get_env(chatterbox, port),
    ClientOptions = [
               binary,
               {packet, raw},
               {active, true}
              ],
    {ok, SSLOptions} = application:get_env(chatterbox, ssl_options),
    Options =  ClientOptions ++ SSLOptions ++ [{client_preferred_next_protocols, {client, [<<"h2">>]}}],

    Transport = ssl,

    {ok, Socket} = Transport:connect("localhost", Port, Options),

    Transport:send(Socket, <<?PREAMBLE>>),

    %% Now send client settings so the problem becomes that we do not ack
    ClientSettings = #settings{},
    http2_frame_settings:send({Transport, Socket}, #settings{}, ClientSettings),
    %% Settings Frame

    %% Two receives. one for server settings, and one for client settings ack
    Fun = fun () ->
                  receive
                      {_, _, Bin} ->
                          ct:pal("Received Bin: ~p", [Bin]),
                          ok
                  end
          end,
    Fun(),
    Fun(),

    %% Since we never send our ack, we should get a settings timeout in 5000ms
    ct:pal("waiting for timeout, should arrive in 5000ms"),
    receive
        {_, _, GoAwayBin} ->
            ct:pal("GoAwayBin: ~p", [GoAwayBin]),
            [{FH, GoAway}] = http2_frame:from_binary(GoAwayBin),
            ct:pal("Type: ~p", [FH#frame_header.type]),
            ?GOAWAY = FH#frame_header.type,
            ?SETTINGS_TIMEOUT = GoAway#goaway.error_code
    after 6000 ->
            ?assert(false)
    end,
    ok.

protocol_error_on_never_send_client_settings(Config) ->
    chatterbox_test_buddy:start([{ssl, true}|Config]),

    {ok, Port} = application:get_env(chatterbox, port),
    ClientOptions = [
               binary,
               {packet, raw},
               {active, true}
              ],
    {ok, SSLOptions} = application:get_env(chatterbox, ssl_options),
    Options =  ClientOptions ++ SSLOptions ++ [{client_preferred_next_protocols, {client, [<<"h2">>]}}],

    Transport = ssl,

    {ok, Socket} = Transport:connect("localhost", Port, Options),

    Transport:send(Socket, <<?PREAMBLE>>),
    %% Settings Frame
    receive
        %% This is the settings frame. Do not ACK
        _ -> ok
    end,

    ct:pal("waiting for timeout, should arrive in 5000ms"),

    receive
        {_, _, GoAwayBin} ->
            ct:pal("GoAwayBin: ~p", [GoAwayBin]),
            [{FH, GoAway}] = http2_frame:from_binary(GoAwayBin),
            ct:pal("Type: ~p", [FH#frame_header.type]),
            ?GOAWAY = FH#frame_header.type,
            ?PROTOCOL_ERROR = GoAway#goaway.error_code
    after 6000 ->
            ?assert(false)
    end,
    ok.

default_setting_honored_before_ack(_Config) ->
    %% configure settings for smaller frame size, 2048

    %% send frame with 2048 < size < 16384

    %% send ack

    %% send frame size > 2048, now should fail
    ok.
