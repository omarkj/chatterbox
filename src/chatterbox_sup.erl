-module(chatterbox_sup).

-behaviour(supervisor).

-export([
         init/1,
         start_link/0,
         start_socket/0
        ]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, Port} = application:get_env(port),
    Options = [
        binary,
        {reuseaddr, true},
        {packet, raw},
        {backlog, 1024},
        {active, false}
    ],
    {ok, SSLEnabled} = application:get_env(ssl),
    {Transport, SSLOptions} = case SSLEnabled of
        true ->
            {ok, SSLOpts} = application:get_env(ssl_options),
            {ssl, SSLOpts};
        false ->
            {gen_tcp, []}
    end,

    spawn_link(fun empty_listeners/0),
    {ok, ListenSocket} = gen_tcp:listen(Port, Options),
    Restart = {simple_one_for_one, 60, 3600},
    Children = [{socket,
                {http2_connection, start_link, [[{Transport, ListenSocket}, SSLOptions]]}, % pass the socket!
                temporary, 1000, worker, [http2_connection]}],
    {ok, {Restart, Children}}.

start_socket() ->
    supervisor:start_child(?MODULE, []).

empty_listeners() ->
    {ok, ConcurrentAcceptors} = application:get_env(concurrent_acceptors),
    [ start_socket() || _ <- lists:seq(1,ConcurrentAcceptors)].
