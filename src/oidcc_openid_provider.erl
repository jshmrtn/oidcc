-module(oidcc_openid_provider).
-behaviour(gen_server).

%% API.
-export([start_link/1]).
-export([set_name/2]).
-export([set_description/2]).
-export([set_client_id/2]).
-export([set_client_secret/2]).
-export([set_config_endpoint/2]).
-export([update_config/1]).
%% -export([force_update_config/1]).
-export([set_local_endpoint/2]).
-export([get_config/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
          id = undefined,
          name = undefined,
          desc = none,
          client_id = unknown,
          client_secret = unknown,
          config_ep = unknown,
          config = #{},
          keys = [],
          ready = false,
          lasttime_updated = never,
          local_endpoint = unknown,

          gun_pid = undefined,
          mref = undefined,
          sref = undefined,
          http = #{},
          retrieving = none
         }).

%% API.

-spec start_link(Id :: binary()) -> {ok, pid()}.
start_link(Id) ->
    gen_server:start_link(?MODULE, Id, []).

-spec set_name(Name :: binary(), Pid :: pid() ) -> ok.
set_name(Name, Pid) ->
    gen_server:call(Pid, {set_name, Name}).

-spec set_description(Description :: binary(), Pid :: pid() ) -> ok.
set_description(Description, Pid) ->
    gen_server:call(Pid, {set_description, Description}).

-spec set_client_id(ClientId :: binary(), Pid :: pid() ) -> ok.
set_client_id(ClientId, Pid) ->
    gen_server:call(Pid, {set_client_id, ClientId}).

-spec set_client_secret(ClientSecret :: binary(), Pid :: pid() ) -> ok.
set_client_secret(ClientSecret, Pid) ->
    gen_server:call(Pid, {set_client_secret, ClientSecret}).


-spec set_config_endpoint(ConfigEndpoint :: binary(), Pid :: pid() ) -> ok.
set_config_endpoint(ConfigEndpoint, Pid) ->
    gen_server:call(Pid, {set_config_endpoint, ConfigEndpoint}).

-spec update_config(Pid :: pid() ) -> ok.
update_config(Pid) ->
    gen_server:call(Pid, update_config).

-spec set_local_endpoint(Url :: binary(), Pid :: pid() ) -> ok.
set_local_endpoint(Url, Pid) ->
    gen_server:call(Pid, {set_local_endpoint, Url}).

-spec get_config( Pid :: pid() ) -> {ok, Config :: map()}.
get_config( Pid) ->
    gen_server:call(Pid, get_config).
%% gen_server.

init(Id) ->
    {ok, #state{id = Id}}.

handle_call(get_config, _From, State) ->
    Conf = create_config(State),
    {reply, {ok, Conf}, State};
handle_call({set_name, Name}, _From, State) ->
    {reply, ok, State#state{name = Name}};
handle_call({set_description, Description}, _From, State) ->
    {reply, ok, State#state{desc = Description}};
handle_call({set_client_id, ClientId}, _From, State) ->
    {reply, ok, State#state{client_id=ClientId}};
handle_call({set_client_secret, ClientSecret}, _From, State) ->
    {reply, ok, State#state{client_secret=ClientSecret}};
handle_call({set_local_endpoint, Url}, _From, State) ->
    {reply, ok, State#state{local_endpoint=Url}};
handle_call({set_config_endpoint, ConfigEndpoint}, _From, State) ->
    ok = trigger_config_retrieval(),
    {reply, ok, State#state{config_ep=ConfigEndpoint}};
handle_call(update_config, _From, State) ->
    ok = trigger_config_retrieval(),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.


handle_cast(retrieve_config, #state{gun_pid = undefined} = State) ->
    {ok, ConPid, MRef, StreamRef} = retrieve_config(State),
    NewState = State#state{gun_pid = ConPid,
                           mref=MRef,
                           sref=StreamRef,
                           retrieving=config},
    {noreply, NewState};
handle_cast(retrieve_keys, State) ->
    {ok, ConPid, MRef, StreamRef} = retrieve_keys(State),
    NewState = State#state{gun_pid = ConPid,
                           mref=MRef,
                           sref=StreamRef,
                           retrieving=keys},
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.



handle_info({gun_response, ConPid, StreamRef, fin, Status, Header},
            #state{gun_pid=ConPid, sref=StreamRef} = State) ->
    Http = #{status => Status, header => Header, body => <<>>},
    NewState = handle_http_result(State#state{http=Http}),
    {noreply, NewState};
handle_info({gun_response, ConPid, StreamRef, nofin, Status, Header},
            #state{gun_pid=ConPid, sref=StreamRef} = State) ->
    NewState = State#state{http = #{status => Status,
                                    header => Header}},
    {noreply, NewState};
handle_info({gun_data, ConPid, StreamRef, nofin, Data},
            #state{gun_pid=ConPid, sref=StreamRef, http=Http} = State) ->
    OldBody = maps:get(body, Http, <<>>),
    NewBody = << OldBody/binary, Data/binary >>,
    NewState = State#state{http=maps:put(body, NewBody, Http)},
    {noreply, NewState};
handle_info({gun_data, ConPid, StreamRef, fin, Data},
            #state{gun_pid=ConPid, sref=StreamRef, http=Http} = State) ->
    OldBody = maps:get(body, Http, <<>>),
    Body = << OldBody/binary, Data/binary >>,
    NewState = handle_http_result(State#state{http=maps:put(body, Body, Http)}),
    {noreply, NewState};
handle_info({'DOWN', MRef, process, ConPid, Reason},
            #state{gun_pid=ConPid, mref = MRef} = State) ->
    State2 = handle_http_client_crash(Reason, State),
    {stop, normal, State2};
handle_info(_Info, State) ->
    {noreply, State}.



terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

retrieve_config(#state{config_ep = ConfigEndpoint}) ->
    gun_get(ConfigEndpoint).

retrieve_keys(#state{config = Config}) ->
    KeyEndpoint = maps:get(jwks_uri, Config, undefined),
    Header = [{<<"accept">>, "application/json"}],
    gun_get(KeyEndpoint, Header).

handle_http_result(200, Header, Body, config, State) ->
    handle_config(Body, Header, State);
handle_http_result(200, Header, Body, keys, State) ->
    handle_keys(Body, Header, State);
handle_http_result(_Status, _Header, _Body, _Retrieve, State) ->
    State.


handle_http_result(#state{ retrieving = Retrieve, http =Http} = State) ->
    #{header := Header, status := Status, body := InBody} = Http,
    State2 = State#state{gun_pid=undefined, retrieving=undefined, http=#{}},
    {ok, Body} = uncompress_body_if_needed(InBody, Header),
    handle_http_result(Status, Header, Body, Retrieve, State2).


create_config(#state{id = Id, desc = Desc, client_id = ClientId,
                     client_secret = ClientSecret, config_ep = ConfEp,
                     config=Config, keys = Keys,
                     lasttime_updated = LastTimeUpdated, ready = Ready,
                     local_endpoint = LocalEndpoint}) ->
    StateList = [{id, Id}, {description, Desc}, {client_id, ClientId},
                 {client_secret, ClientSecret}, {config_endpoint, ConfEp},
                 {lasttime_updated, LastTimeUpdated}, {ready, Ready},
                 {local_endpoint, LocalEndpoint}, {keys, Keys}],
    maps:merge(Config, maps:from_list(StateList)).





handle_config(Data, _Header, State) ->
    %TODO: implement update at expire data/time
    Config = jsx:decode(Data, [return_maps, {labels, attempt_atom}]),
    ok = trigger_key_retrieval(),
    timer:apply_after(3600000, ?MODULE, update_config, [self()]),
    State#state{config = Config}.

handle_keys(Data, _Header, State) ->
    %TODO: implement update at expire data/time
    #{keys := KeyList}=jsx:decode(Data, [return_maps, {labels, attempt_atom}]),
    Keys = extract_supported_keys(KeyList, []),
    State#state{keys  = Keys, ready = true, lasttime_updated = timestamp(),
                gun_pid = undefined}.

extract_supported_keys([], List) ->
    List;
extract_supported_keys([#{ kty := <<"RSA">>,
                           alg := <<"RS256">>,
                           use := <<"sig">>,
                           n := N0,
                           e := E0
                         } = Map|T], List) ->
    Kid = maps:get(kid, Map, unknown),
    N = binary:decode_unsigned(base64url:decode(N0)),
    E = binary:decode_unsigned(base64url:decode(E0)),
    Key = #{kty => rsa, alg => rs256, use => sign, key => [E, N], kid => Kid },
    extract_supported_keys(T, [Key | List]);
extract_supported_keys([_H|T], List) ->
    extract_supported_keys(T, List).



handle_http_client_crash(State, _Reason) ->
    trigger_config_retrieval(),
    State#state{gun_pid = undefined, retrieving= undefined, http=#{}}.

trigger_config_retrieval() ->
    gen_server:cast(self(), retrieve_config).

trigger_key_retrieval() ->
    gen_server:cast(self(), retrieve_keys).

timestamp() ->
    erlang:system_time(seconds).

gun_get(Url) ->
    gun_get(Url, []).

gun_get(Url, Header) ->
    Uri = uri:from_string(Url),
    Host= binary:bin_to_list(uri:host(Uri)),
    Port0 = uri:port(Uri),
    Scheme = uri:scheme(Uri),
    Config = scheme_to_map(Scheme),
    Path = binary:bin_to_list(uri:path(Uri)),
    Port = ensure_port(Port0, Scheme),
    {ok, ConPid} = gun:open(Host, Port, Config),
    MRef = monitor(process, ConPid),
    {ok, _Protocol} = gun:await_up(ConPid),
    StreamRef = gun:get(ConPid, Path, Header),
    ok = gun:shutdown(ConPid),
    {ok, ConPid, MRef, StreamRef}.

scheme_to_map(<<"http">>) ->
    #{};
scheme_to_map(<<"https">>) ->
    #{transport => ssl};
scheme_to_map(_) ->
    #{transport => ssl}.


ensure_port(undefined, <<"http">>) ->
    80;
ensure_port(undefined, <<"https">>) ->
    443;
ensure_port(Port, _) when is_number(Port) ->
    Port;
ensure_port(_Port, _)  ->
    443.


uncompress_body_if_needed(Body, Header) when is_list(Header) ->
    Encoding = lists:keyfind(<<"content-encoding">>, 1, Header),
    uncompress_body_if_needed(Body, Encoding);
uncompress_body_if_needed(Body, false)  ->
    {ok, Body};
uncompress_body_if_needed(Body, {_, <<"gzip">>})  ->
    {ok, zlib:gunzip(Body)};
uncompress_body_if_needed(Body, {_, <<"deflate">>})  ->
    Z  = zlib:open(),
    ok = zlib:inflateInit(Z),
    {ok, zlib:inflate(Z, Body)};
uncompress_body_if_needed(_Body, {_, Compression})  ->
    erlang:error({unsupported_encoding, Compression}).

