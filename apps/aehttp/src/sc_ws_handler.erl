-module(sc_ws_handler).

%% WS API
-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).

-export([error_msg/1,
         error_data_msg/1]).

-record(handler, {fsm_pid            :: pid() | undefined,
                  fsm_mref           :: reference() | undefined,
                  fsm_version        :: non_neg_integer(),
                  channel_id         :: aesc_channels:id() | undefined,
                  enc_channel_id     :: aehttp_api_encoder:encoded() | undefined,
                  job_id             :: term(),
                  protocol           :: sc_ws_api:protocol(), 
                  orig_request       :: map() | undefined,
                  role               :: initiator | responder | undefined,
                  host               :: binary() | undefined,
                  port               :: non_neg_integer() | undefined}).

-opaque handler() :: #handler{}.
-export_type([handler/0]).
-define(METHOD_SIGNED(Method), Method =:= <<"channels.initiator_sign">>;
                               Method =:= <<"channels.deposit_tx">>;
                               Method =:= <<"channels.deposit_ack">>;
                               Method =:= <<"channels.withdraw_tx">>;
                               Method =:= <<"channels.withdraw_ack">>;
                               Method =:= <<"channels.responder_sign">>;
                               Method =:= <<"channels.shutdown_sign">>;
                               Method =:= <<"channels.shutdown_sign_ack">>;
                               Method =:= <<"channels.update">>;
                               Method =:= <<"channels.update_ack">>).
-define(METHOD_TAG(Method), case Method of
                                <<"channels.initiator_sign">>    -> create_tx;
                                <<"channels.deposit_tx">>        -> deposit_tx;
                                <<"channels.deposit_ack">>       -> deposit_created;
                                <<"channels.withdraw_tx">>       -> withdraw_tx;
                                <<"channels.withdraw_ack">>      -> withdraw_created;
                                <<"channels.responder_sign">>    -> funding_created;
                                <<"channels.update">>            -> update;
                                <<"channels.update_ack">>        -> update_ack;
                                <<"channels.shutdown_sign">>     -> shutdown;
                                <<"channels.shutdown_sign_ack">> -> shutdown_ack;
                                <<"channels.leave">>             -> leave
                            end).
-define(FSM_VERSION, 1).

init(Req, _Opts) ->
    lager:debug("init(~p, ~p)", [Req, _Opts]),
    {cowboy_websocket, Req,
     maps:merge(#{<<"protocol">> => <<"legacy">>,
                  <<"fsm_version">>  => ?FSM_VERSION},
                maps:from_list(cowboy_req:parse_qs(Req)))}.

-spec websocket_init(map()) -> {ok, handler()} | {stop, undefined}.
websocket_init(Params) ->
    case {prepare_handler(Params), read_channel_options(Params)} of
        {{error, Err}, _} ->
            lager:info("Channel WS failed to start because of ~p; params ~p",
                       [Err, Params]),
            {stop, undefined};
        {_, {error, Err}} ->
            lager:info("Channel WS failed to start because of ~p; params ~p",
                       [Err, Params]),
            {stop, undefined};
        {Handler, ChannelOpts} ->
            lager:debug("Starting Channel WS with params ~p", [Params]),
            {ok, FsmPid} = start_link_fsm(Handler, ChannelOpts),
            MRef = erlang:monitor(process, FsmPid),
            {ok, Handler#handler{fsm_pid = FsmPid, fsm_mref = MRef}}
    end.

-spec websocket_handle(term(), handler()) -> {ok, handler()}.
websocket_handle({text, MsgBin}, #handler{protocol = Protocol,
                                          fsm_pid  = FsmPid} = H) ->
    case sc_ws_api:process_from_client(Protocol, MsgBin, FsmPid) of
        no_reply          -> {ok, H};
        {reply, Resp}     -> {reply, {text, jsx:encode(Resp)}, H};
        stop              -> {stop, H}
    end;
websocket_handle(_Data, H) ->
    {ok, H}.

websocket_info(Msg, #handler{} = H) ->
    try_seq([ fun unpack_info/2
            , fun websocket_info_/2 ], Msg, H).

try_seq(Seq, Msg, #handler{} = H) ->
    %% All funs in `Seq` except the last, are to return `{Msg', H'}`.
    %% The expected return values of the last fun are explicit below.
    try lists:foldl(fun(F, {M1, #handler{} =H1}) ->
                            F(M1, H1)
                    end, {Msg, H}, Seq) of
        no_reply          -> {ok, reset_h(H)};
        {ok, H1}          -> {ok, reset_h(H1)};
        {reply, Resp}     -> {reply, {text, jsx:encode(Resp)}, reset_h(H)};
        {reply, Resp, H1} -> {reply, {text, jsx:encode(Resp)}, reset_h(H1)};
        {stop, H1}        -> {stop, reset_h(H1)}
    catch
        throw:{decode_error, Reason} ->
            lager:debug("CAUGHT THROW {decode_error, ~p} (Msg = ~p)",
                        [Reason, Msg]),
            {reply, Err} = error_response(Reason, H),
            {reply, {text, jsx:encode(Err), H}};
        throw:{die_anyway, E} ->
            lager:debug("CAUGHT THROW E = ~p / Msg = ~p / ~p",
                        [E, Msg, erlang:get_stacktrace()]),
            erlang:error(E);
        error:E ->
            lager:debug("CAUGHT E=~p / Msg = ~p / ~p", [E, Msg, erlang:get_stacktrace()]),
            {ok, H}
    end.

reset_h(H) ->
    H#handler{orig_request = undefined}.

websocket_info_({aesc_fsm, FsmPid, Msg}, #handler{fsm_pid=FsmPid}=H) ->
    H1 = set_channel_id(Msg, H),
    process_fsm(Msg, H1);
websocket_info_({'DOWN', MRef, _, _, _}, #handler{fsm_mref = MRef} = H) ->
    {stop, H#handler{fsm_pid = undefined,
                     fsm_mref = undefined}};
websocket_info_(_Info, State) ->
    {ok, State}.

set_channel_id(Msg, H) ->
    Res = set_channel_id_(Msg, H),
    lager:debug("Msg=~p (Id0=~p) -> ~p", [Msg, H#handler.channel_id,
                                          Res#handler.channel_id]),
    Res.

set_channel_id_(#{channel_id := Id},
               #handler{channel_id = undefined} = H) when Id =/= undefined ->
    H#handler{channel_id = Id,
              enc_channel_id = aehttp_api_encoder:encode(channel, Id)};
set_channel_id_(#{channel_id := A}, #handler{channel_id = B})
  when A =/= undefined, A =/= B ->
    erlang:error({channel_id_mismatch, [A, B]});
set_channel_id_(_Msg, H) ->
    H.

fsm_reply(Msg, #handler{enc_channel_id = Id} = H) ->
    lager:debug("fsm_reply( Id = ~p )", [Id]),
    case Id of
        undefined -> reply(Msg, H);
        _         -> reply(maps:merge(#{channel_id => Id}, Msg), H)
    end.


terminate(_Reason, _PartialReq, #{} = _H) ->
    % not initialized yet
    ok;
terminate(Reason, _PartialReq, State) ->
    lager:debug("WebSocket dying because of ~p/~p", [Reason, erlang:get_stacktrace()]),
    case fsm_pid(State) of
        undefined -> pass;
        FsmPid ->
            true = unlink(FsmPid),
            ok = aesc_fsm:client_died(FsmPid)
    end,
    jobs:done(job_id(State)),
    ok.

-spec job_id(handler()) -> term().
job_id(#handler{job_id = JobId}) ->
    JobId.

-spec channel_id(handler()) -> aesc_channels:id() | undefined.
channel_id(#handler{channel_id = ChannelId}) ->
    ChannelId.

-spec fsm_pid(handler()) -> pid() | undefined.
fsm_pid(#handler{fsm_pid = Pid}) ->
    Pid.

-spec process_response(term(), list()) -> ok.
process_response(Response, Options) ->
    lists:foreach(
        fun({Key, Fun}) ->
            case proplists:get_value(Key, Options) of
                undefined -> pass;
                Value -> Fun(Value)
            end
        end,
        [{sender, fun(SenderPid) -> SenderPid ! {ws_proc_response, Response} end}]),
    ok.

-spec is_ws_alive(pid()) -> boolean().
is_ws_alive(Pid) ->
    case erlang:process_info(Pid) of
        undefined -> false;
        _ -> true
    end.

-spec start_link_fsm(handler(), map()) -> {ok, pid()}.
start_link_fsm(#handler{role = initiator, host=Host, port=Port}, Opts) ->
    {ok, _Pid} = aesc_fsm:initiate(Host, Port, Opts);
start_link_fsm(#handler{role = responder, port=Port}, Opts) ->
    {ok, _Pid} = aesc_fsm:respond(Port, Opts).

set_field(H, host, Val)         -> H#handler{host = Val};
set_field(H, role, Val)         -> H#handler{role = Val};
set_field(H, port, Val)         -> H#handler{port = Val};
set_field(H, fsm_version, Val)  -> H#handler{fsm_version = Val}.

-spec read_param(binary(), atom(), map()) -> fun((map()) -> {ok, term()} |
                                                            not_set |
                                                            {error, {atom(), atom()}}).
read_param(ParamName, RecordField, Options) ->
    fun(Params) ->
        Mandatory = maps:get(mandatory, Options, true),
        case maps:get(ParamName, Params, undefined) of
            undefined when Mandatory ->
                {error, {RecordField, missing}};
            undefined when not Mandatory ->
                not_set;
            Val0 ->
                Type = maps:get(type, Options, binary),
                case parse_by_type(Type, Val0, RecordField) of
                    {error, _} = Err -> Err;
                    {ok, Val} ->
                        case maps:get(enum, Options, undefined) of
                            undefined ->  {ok, Val};
                            AllowedVals when is_list(AllowedVals) ->
                                case lists:member(Val, AllowedVals) of
                                    true -> {ok, Val};
                                    false ->
                                        {error, {RecordField, invalid}}
                                end
                        end
                end
        end
    end.

parse_by_type(binary, V, _) when is_binary(V) ->
    {ok, V};
parse_by_type(boolean, V, _) when is_binary(V) ->
    case V of
        <<"true">>  -> {ok, true};
        <<"false">> -> {ok, false};
        _           -> {error, not_bool}
    end;
parse_by_type(string, V, _) when is_binary(V) ->
    {ok, binary_to_list(V)};
parse_by_type(atom, V, _) when is_binary(V) ->
    {ok, binary_to_existing_atom(V, utf8)};
parse_by_type(integer, V, _) when is_binary(V) ->
    {ok, list_to_integer(binary_to_list(V))};
parse_by_type(integer, V, _) when is_integer(V) ->
    {ok, V};
parse_by_type({hash, Type}, V, RecordField) when is_binary(V) ->
    case aehttp_api_encoder:safe_decode(Type, V) of
        {error, _} ->
            {error, {RecordField, broken_encoding}};
        {ok, _} = OK -> OK
    end;
parse_by_type(serialized_tx, V, RecordField) when is_binary(V) ->
    case aehttp_api_encoder:safe_decode(transaction, V) of
        {ok, TxBin} ->
            try {ok, aetx_sign:deserialize_from_binary(TxBin)}
            catch
                error:_ ->
                    {error, {RecordField, invalid_tx_serialization}}
            end;
        {error, _} ->
            {error, {RecordField, broken_encoding}}
    end.

-spec process_fsm(term(), handler()) -> no_reply | {reply, map()} | {error, atom()}.
process_fsm(#{type := sign,
              tag  := Tag,
              info := Tx}, H) when Tag =:= create_tx
                            orelse Tag =:= deposit_tx
                            orelse Tag =:= deposit_created
                            orelse Tag =:= withdraw_tx
                            orelse Tag =:= withdraw_created
                            orelse Tag =:= shutdown
                            orelse Tag =:= shutdown_ack
                            orelse Tag =:= funding_created
                            orelse Tag =:= update
                            orelse Tag =:= update_ack ->
    EncTx = aehttp_api_encoder:encode(transaction, aetx:serialize_to_binary(Tx)),
    Tag1 =
        case Tag of
            create_tx -> <<"initiator_sign">>;
            funding_created -> <<"responder_sign">>;
            shutdown -> <<"shutdown_sign">>;
            shutdown_ack -> <<"shutdown_sign_ack">>;
            deposit_created -> <<"deposit_ack">>;
            withdraw_created -> <<"withdraw_ack">>;
            T -> atom_to_binary(T, utf8)
        end,
    Protocol = H#handler.protocol,
    sc_ws_api:notify(Protocol, #{action  => <<"sign">>,
                                 tag => Tag1,
                                 payload => #{tx => EncTx}});
process_fsm(#{type := report,
              tag  := Tag,
              info := Event}, H) when Tag =:= info
                               orelse Tag =:= update
                               orelse Tag =:= conflict
                               orelse Tag =:= message
                               orelse Tag =:= leave
                               orelse Tag =:= error
                               orelse Tag =:= debug
                               orelse Tag =:= on_chain_tx ->
    Payload =
        case {Tag, Event} of
            {info, {died, _}} -> #{event => <<"died">>};
            {info, _} when is_atom(Event) -> #{event => atom_to_binary(Event, utf8)};
            {on_chain_tx, Tx} ->
                EncodedTx = aehttp_api_encoder:encode(transaction,
                                               aetx_sign:serialize_to_binary(Tx)),
                #{tx => EncodedTx};
            {_, NewState} when Tag == update; Tag == leave ->
                Bin = aehttp_api_encoder:encode(transaction,
                                         aetx_sign:serialize_to_binary(NewState)),
                #{state => Bin};
            {conflict, #{channel_id := ChId,
                         round      := Round}} ->
                         #{channel_id => aehttp_api_encoder:encode(channel, ChId),
                           round => Round};
            {message, #{channel_id  := ChId,
                        from        := From,
                        to          := To,
                        info        := Info}} ->
                #{message => #{channel_id => aehttp_api_encoder:encode(channel, ChId),
                               from => aehttp_api_encoder:encode(account_pubkey, From),
                               to => aehttp_api_encoder:encode(account_pubkey, To),
                               info => Info}};
            {error, Msg} -> #{message => Msg};
            {debug, Msg} -> #{message => Msg}
        end,
    Action = atom_to_binary(Tag, utf8),
    fsm_reply(#{action => Action,
                payload => Payload,
                tag     => none}, H);
process_fsm(#{type := Type, tag := Tag, info := Event}, _H) ->
    error({unparsed_fsm_event, Type, Tag, Event}).

prepare_handler(#{<<"protocol">> := Protocol} = Params) ->
    lager:debug("prepare_handler() Params = ~p", [Params]),
    Read =
        fun(Key, RecordField, Opts) ->
            fun(H) ->
                case (read_param(Key, RecordField, Opts))(Params) of
                    not_set -> H;
                    {ok, Val} -> set_field(H, RecordField, Val);
                    {error, _} = Err -> Err
                end
            end
        end,
    Validators =
        [fun(H) ->
            case jobs:ask(ws_handlers) of
                {ok, JobId} ->
                    H#handler{job_id = JobId};
                {error, _} ->
                    {error, too_many_ws_sockets}
            end
        end,
        Read(<<"role">>, role, #{type => atom,
                                 enum => [responder, initiator]}),
        fun(#handler{role = Role} = H) ->
            case Role of
                initiator -> % require having a host only for initiator
                    F = Read(<<"host">>, host, #{type => string}),
                    F(H);
                responder -> H
            end
        end,
        Read(<<"port">>, port, #{type => integer}),
        Read(<<"fsm_version">>, fsm_version, #{type => integer})
        ],
    lists:foldl(
        fun(_, {error, _} = Err) -> Err;
            (Fun, Accum) -> Fun(Accum)
        end,
        #handler{protocol    = sc_ws_api:protocol(Protocol),
                 fsm_version = ?FSM_VERSION}, Validators).

read_channel_options(Params) ->
    Read =
        fun(KeyBin, Key, Opts) ->
            fun(M) ->
                case (read_param(KeyBin, Key, Opts))(Params) of
                    not_set -> M;
                    {ok, Val} -> maps:put(Key, Val, M);
                    {error, _} = Err -> Err
                end
            end
        end,
    Put =
        fun(K, V) ->
            fun(M) -> maps:put(K, V, M) end
        end,
    ReadMap =
        fun(MapName, Prefix, Opts) ->
            fun(Name) ->
                NameBin = atom_to_binary(Name, utf8),
                Key = <<Prefix/binary, "_", NameBin/binary>>,
                fun(M) ->
                    OldVal = maps:get(MapName, M, #{}),
                    case (read_param(Key, Name, Opts))(Params) of
                        not_set -> M;
                        {ok, Val} -> maps:put(MapName, maps:put(Name, Val, OldVal), M);
                        {error, _} = Err -> Err
                    end
                end
            end
        end,
    ReadTimeout = ReadMap(timeouts, <<"timeout">>, #{type => integer,
                                                     mandatory => false}),
    ReadReport = ReadMap(report, <<"report">>, #{type => boolean,
                                                     mandatory => false}),
    lists:foldl(
        fun(_, {error, _} = Err) -> Err;
            (Fun, Accum) -> Fun(Accum)
        end,
        #{},
        [Read(<<"initiator_id">>, initiator, #{type => {hash, account_pubkey}}),
         Read(<<"responder_id">>, responder, #{type => {hash, account_pubkey}}),
         Read(<<"existing_channel_id">>, existing_channel_id,
              #{type => {hash, channel}, mandatory => false}),
         Read(<<"offchain_tx">>, offchain_tx,
              #{type => serialized_tx, mandatory => false}),
         Read(<<"lock_period">>, lock_period, #{type => integer}),
         Read(<<"push_amount">>, push_amount, #{type => integer}),
         Read(<<"initiator_amount">>, initiator_amount, #{type => integer}),
         Read(<<"responder_amount">>, responder_amount, #{type => integer}),
         Read(<<"channel_reserve">>, channel_reserve, #{type => integer}),
         Read(<<"ttl">>, ttl, #{type => integer, mandatory => false}),
         Put(noise, [{noise, <<"Noise_NN_25519_ChaChaPoly_BLAKE2b">>}])
        ] ++ lists:map(ReadTimeout, aesc_fsm:timeouts() ++ [awaiting_open,
                                                            initialized])
          ++ lists:map(ReadReport, aesc_fsm:report_tags())
     ).

error_response(Reason, #handler{protocol = legacy, orig_request = Req}) ->
    {reply, #{ <<"action">>  => <<"error">>
             , <<"payload">> => #{ <<"request">> => Req
                                 , <<"reason">> => legacy_error_reason(Reason)} }
    };
error_response(Reason, #handler{protocol = jsonrpc, orig_request = Req}) ->
    {reply, #{ <<"jsonrpc">> => <<"2.0">>
             , <<"id">>      => error_id(Req)
             , <<"error">>   => json_rpc_error_object(Reason, Req) }
    }.

error_id(#{ <<"id">> := Id }) -> Id;
error_id(_) ->
    null.

%% this should be generalized more
legacy_error_reason({broken_encoding, [accounts, contracts]}) ->
    <<"broken_encoding: accounts, contracts">>;
legacy_error_reason({broken_encoding, [accounts]}) ->
    <<"broken_encoding: accounts">>;
legacy_error_reason({broken_encoding, [contracts]}) ->
    <<"broken_encoding: contracts">>;
legacy_error_reason(Reason) ->
    bin(Reason).

%% JSON-RPC error objects. Try to follow
%% https://github.com/ethereum/wiki/wiki/JSON-RPC-Error-Codes-Improvement-Proposal
json_rpc_error_object(parse_error         , R) -> error_obj(-32700        , R);
json_rpc_error_object(invalid_request     , R) -> error_obj(-32000        , R);
json_rpc_error_object(unhandled           , R) -> error_obj(-32601        , R);
json_rpc_error_object(broken_encoding     , R) -> error_obj(3     , [104] , R);
json_rpc_error_object(broken_code         , R) -> error_obj(3     , [104] , R);
json_rpc_error_object(conflict            , R) -> error_obj(3     , [107] , R);
json_rpc_error_object(insufficient_balance, R) -> error_obj(3     , [1001], R);
json_rpc_error_object(negative_amount     , R) -> error_obj(3     , [1002], R);
json_rpc_error_object(invalid_pubkeys     , R) -> error_obj(3     , [1003], R);
json_rpc_error_object(call_not_found      , R) -> error_obj(3     , [1004], R);
json_rpc_error_object({broken_encoding,What}, R) ->
    error_obj(3, [broken_encoding_code(W) || W <- What], R);
json_rpc_error_object(not_found           , R) -> error_obj(3     , [100] , R);
json_rpc_error_object(Other               , R) ->
    lager:debug("Unrecognized error reason: ~p", [Other]),
    error_obj(-32603        , R).

error_obj(Code, OrigReq) when is_map(OrigReq) ->
    #{ <<"code">>    => Code
     , <<"message">> => error_msg(Code)
     , <<"request">> => OrigReq };
error_obj(Code, undefined) ->
    #{ <<"code">>    => Code
     , <<"message">> => error_msg(Code) }.

error_obj(Code, Data, OrigReq) when is_map(OrigReq) ->
    #{ <<"code">>    => Code
     , <<"message">> => error_msg(Code)
     , <<"data">>    => error_data(Data)
     , <<"request">> => OrigReq };
error_obj(Code, Data, undefined) ->
    #{ <<"code">>    => Code
     , <<"message">> => error_msg(Code)
     , <<"data">>    => error_data(Data) }.

error_msg(Code) ->
    maps:get(Code, error_msgs(), <<"Unknown error">>).

error_msgs() ->
    #{
       -32700 => <<"Parse error">>
     , -32000 => <<"Invalid request">>
     , -32601 => <<"Method not found">>
     , -32602 => <<"Invalid params">>
     , -32603 => <<"Internal error">>
       %% Ethereum application error codes
     , 1      => <<"Unauthorized">>
     , 2      => <<"Action not allowed">>
     , 3      => <<"Rejected">>
     }.

error_data(Codes) ->
    [ #{ <<"code">>    => C
       , <<"message">> => error_data_msg(C) } || C <- Codes].

%% Mimicking Ethereum suggested custom error codes (not all relevant here)
error_data_msg(Code) ->
    maps:get(Code, error_data_msgs(), <<"Unknown error">>).

error_data_msgs() ->
    #{
       100 => <<"X doesn't exist">>
     , 101 => <<"Requires coin">>      %% (Requires ether)
     , 102 => <<"Gas too low">>
     , 103 => <<"Gas limit exceeded">>
     , 104 => <<"Rejected">>
     , 105 => <<"Value too low">>      %% (Ether too low)
     , 106 => <<"Timeout">>
     , 107 => <<"Conflict">>
     %% Aeternity error codes
     , 1001 => <<"Insufficient balance">>
     , 1002 => <<"Negative amount">>
     , 1003 => <<"Invalid pubkeys">>
     , 1004 => <<"Call not found">>
     , 1005 => <<"Broken encoding: accounts">>
     , 1006 => <<"Broken encoding: contracts">>
     }.

broken_encoding_code(accounts ) -> 1005;
broken_encoding_code(contracts) -> 1006.

unpack_info(Msg, #handler{protocol = Protocol} = H) ->
    Req = info_to_req(Protocol, Msg),
    { Msg, H#handler{orig_request = Req} }.

info_to_req(_, {aesc_fsm, _, #{type := Type, tag := Tag} = Req})
  when Type == report; Type == info; Type == sign ->
    Method = iolist_to_binary(["channels.", atom_to_list(Type), ".", atom_to_list(Tag)]),
    #{ <<"method">> => Method
     , <<"params">> => Req };
info_to_req(_, _) ->
    undefined.

reply(Payload, #handler{protocol = legacy, orig_request = undefined}) ->
    {reply, clean_reply(Payload)};
reply(Payload, #handler{protocol = legacy, orig_request = #{<<"method">> := Method}}) ->
    {reply, legacy_notify(Method, Payload)};
reply(Reply, #handler{protocol = jsonrpc} = H) ->
    json_rpc_reply(Reply, H).

legacy_notify(Method, Reply) ->
    lager:debug("legacy_notify(~p, ~p)", [Method, Reply]),
    case binary:split(Method, [<<".">>], [global]) of
        [<<"channels">>, Action, _Tag] ->
            Action1 = opt_maps_get(action, Reply, Action),
            Msg = opt_elems([tag, channel_id], #{ <<"action">> => Action1 }, Reply),
            add_payload(Reply, Msg);
        [<<"channels">>, Action] ->
            Action1 = opt_maps_get(action, Reply, Action),
            Msg = opt_elems([tag, channel_id], #{ <<"action">> => Action1 }, Reply),
            add_payload(Reply, Msg)
    end.

opt_elems(Keys, Msg, Reply) when is_map(Reply) ->  % Reply may not be a map
    M = lists:foldl(
          fun(K, Acc) ->
                  case maps:find(K, Reply) of
                      {ok, none} -> Acc;
                      {ok, V} ->
                          Kb = bin(K),
                          Acc#{ Kb => V };
                      error ->
                          Acc
                  end
          end, #{}, Keys),
    maps:merge(M, Msg);
opt_elems(_, Msg, _) ->
    Msg.

opt_maps_get(Key, Map, Default) when is_map(Map) ->
    maps:get(Key, Map, Default);
opt_maps_get(_ , _, Default) ->
    Default.

add_payload(#{payload := Payload}, Msg) -> Msg#{<<"payload">> => Payload};
add_payload(#{action := _}       , Msg) -> clean_reply(Msg);
add_payload(Reply                , Msg) ->
    Msg#{<<"payload">> => clean_reply(Reply)}.

json_rpc_reply(Reply, H) ->
    json_rpc_reply(Reply, H, notify).

json_rpc_reply(Reply, #handler{orig_request = Req} = H, Mode) ->
    lager:debug("json_rpc_reply(~p, Req = ~p, Mode = ~p)", [Reply, Req, Mode]),
    case {Req, Mode} of
        {#{<<"id">> := Id}, _} ->
            {reply, #{ <<"jsonrpc">> => <<"2.0">>
                     , <<"id">>      => Id
                     , <<"result">>  => result(Reply) }
            };
        {_, notify} ->
            {reply, #{ <<"jsonrpc">> => <<"2.0">>
                     , <<"method">>  => legacy_to_method_out(Reply)
                     , <<"params">>  => notify_result(Reply, H) } };
        {_, no_reply} ->
            no_reply
    end.

result(#{payload := Payload0} = R) ->
    Payload = clean_reply(Payload0),
    case {Payload, R} of
        {#{channel_id := _}, _} ->
            Payload;
        {_, #{channel_id := Id}} when is_map(Payload) ->
            Payload#{<<"channel_id">> => Id};
        _ ->
            Payload
    end;
result(Result) -> 
    clean_reply(Result).

notify_result(#{payload := Payload0} = R, #handler{enc_channel_id = Id0}) ->
    Payload = clean_reply(Payload0),
    case {Payload, R} of
        {#{channel_id := Id}, _} ->
            #{ channel_id => Id
             , data => maps:remove(channel_id, Payload) };
        {_, #{channel_id := Id}} ->
            #{ channel_id => Id
             , data => Payload };
        _ ->
            #{ channel_id => Id0
             , data => Payload }
    end;
notify_result(R, #handler{enc_channel_id = Id0}) ->
    case R of
        #{channel_id := Id} ->
            #{ channel_id => Id};
        _ ->
            #{ channel_id => Id0 }
    end.


clean_reply(Map) when is_map(Map) ->
    maps:filter(fun(K,_) ->
                        is_atom(K) orelse is_binary(K)
                end, Map);
clean_reply(Msg) -> Msg.

legacy_to_method_in(Action) ->
    <<"channels.", Action/binary>>.

legacy_to_method_in(Action, Tag) ->
    <<"channels.", Action/binary, ".", Tag/binary>>.

legacy_to_method_out(#{action := Action, tag := none} = Msg) ->
    opt_type(Msg, <<"channels.", (bin(Action))/binary>>);
legacy_to_method_out(#{action := Action, tag := Tag} = Msg) ->
    opt_type(Msg, <<"channels.", (bin(Action))/binary, ".", (bin(Tag))/binary>>);
legacy_to_method_out(#{action := Action} = Msg) ->
    opt_type(Msg, <<"channels.", (bin(Action))/binary>>).

opt_type(#{ {int,type} := T }, Bin) ->
    <<Bin/binary, ".", (bin(T))/binary>>;
opt_type(_, Bin) ->
    Bin.

reply(_, #handler{protocol = legacy}, no_reply) ->
    no_reply;
reply(Reply, #handler{protocol = jsonrpc} = H, _) ->
    json_rpc_reply(Reply, H, no_reply).

bin(A) when is_atom(A)   -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B.
