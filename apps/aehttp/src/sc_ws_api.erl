-module(sc_ws_api).

-define(PROTOCOLS, [legacy, jsonrpc]).

%TODO type -> opaque
-type protocol() :: legacy | jsonrpc.
-opaque response() :: {reply, map()} | no_reply | stop.

-export_type([protocol/0,
              response/0]).

-export([protocol/1,
         process_from_client/4,
         notify/3
        ]).

%%%===================================================================
%%% Behaviour definition
%%%===================================================================

-callback unpack(Msg :: map() | list(map())) ->
    Req :: map() | list(Req :: map()).

-callback error_response(Reason :: atom(), OrigMsg :: map() | binary()) ->
    {reply, map()}.

-callback reply(response(), OrigMsg :: map(), ChannelId :: binary()) ->
    {reply, map()} | no_reply | stop.

-callback notify(map(), ChannelId :: binary()) ->
    {reply, map()}.

-callback process_incoming(Msg :: map() | list(map()), FsmPid :: pid()) ->
    {reply, map()} | no_reply | stop.

%%%===================================================================
%%% API
%%%===================================================================

-spec protocol(binary()) -> protocol().
protocol(P) ->
    case P of
        <<"legacy">>   -> legacy;
        <<"json-rpc">> -> jsonrpc;
        _Other ->
            erlang:error(invalid_protocol)
    end.

-spec process_from_client(protocol(), binary(), pid(), binary())
    -> no_reply | {reply, binary()} | stop.
process_from_client(Protocol, MsgBin, FsmPid, ChannelId) ->
    Mod = protocol_to_impl(Protocol),
    try_seq([ fun jsx_decode/1
            , fun unpack_request/1
            , fun process_incoming/1 ], #{api        => Mod,
                                          fsm        => FsmPid,
                                          msg        => MsgBin,
                                          channel_id => ChannelId}).
protocol_to_impl(Protocol) ->
    case Protocol of
        jsonrpc -> sc_ws_api_jsonrpc;
        legacy  -> sc_ws_api_legacy
    end.

notify(Protocol, Msg, ChannelId) ->
    Mod = protocol_to_impl(Protocol),
    Mod:notify(Msg, ChannelId).

unpack_request(#{orig_msg := Msg, api := Mod} = Data) ->
    Unpacked = Mod:unpack(Msg),
    Data#{unpacked_msg => Unpacked}.

-spec try_seq(list(), map()) -> no_reply |
                                {reply, binary()} |
                                stop.
try_seq(Seq, #{msg := Msg, api := Mod} = Data0) ->
    %% All funs in `Seq` except the last, are to return `{Msg', H'}`.
    %% The expected return values of the last fun are explicit below.
    try lists:foldl(fun(F, Data) ->
                            F(Data)
                    end, Data0, Seq) of
        no_reply             -> no_reply;
        {ok, _Data}          -> no_reply;
        {reply, Resp}        -> {reply, Resp};
        stop                 -> stop
    catch
        throw:{decode_error, Reason} ->
            lager:debug("CAUGHT THROW {decode_error, ~p} (Msg = ~p)",
                        [Reason, Msg]),
            no_reply;
        throw:{die_anyway, E} ->
            lager:debug("CAUGHT THROW E = ~p / Msg = ~p / ~p",
                        [E, Msg, erlang:get_stacktrace()]),
            erlang:error(E);
        error:E ->
            lager:debug("CAUGHT E=~p / Msg = ~p / ~p", [E, Msg, erlang:get_stacktrace()]),
            no_reply
    end.

jsx_decode(#{msg := Msg} = Data) ->
    try Data#{orig_msg => jsx:decode(Msg, [return_maps])}
    catch
        error:_ ->
            throw({decode_error, parse_error})
    end.

process_incoming(#{api := Mod, unpacked_msg := Msg, fsm := FsmPid,
                   channel_id := ChannelId}) ->
    Response = Mod:process_incoming(Msg, FsmPid),
    Mod:reply(Response, Msg, ChannelId).
