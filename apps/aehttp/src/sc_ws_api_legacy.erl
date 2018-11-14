-module(sc_ws_api_legacy).

-behavior(sc_ws_api).

-export([unpack/1,
         error_response/2,
         reply/2,
         notify/1,
         process_incoming/2
        ]).


-spec unpack(map()) -> map().
unpack(#{ <<"action">>  := Action
        ,  <<"tag">>     := Tag
        ,  <<"payload">> := Payload }) ->
    Method = legacy_to_method_in(Action, Tag),
    #{ <<"method">> => Method
     , <<"params">> => Payload };
unpack(#{ <<"action">>  := Action
        , <<"payload">> := Payload}) ->
    Method = legacy_to_method_in(Action),
    #{ <<"method">> => Method
     , <<"params">> => Payload};
unpack(#{ <<"action">> := Action }) ->
    Method = legacy_to_method_in(Action),
    #{ <<"method">> => Method }.
    

error_response(Reason, Req) ->
    {reply, #{ <<"action">>  => <<"error">>
             , <<"payload">> => #{ <<"request">> => Req
                                 , <<"reason">> => legacy_error_reason(Reason)} }
    }.

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

bin(A) when is_atom(A)   -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B.

%% this should be generalized more
legacy_error_reason({broken_encoding, [accounts, contracts]}) ->
    <<"broken_encoding: accounts, contracts">>;
legacy_error_reason({broken_encoding, [accounts]}) ->
    <<"broken_encoding: accounts">>;
legacy_error_reason({broken_encoding, [contracts]}) ->
    <<"broken_encoding: contracts">>;
legacy_error_reason(Reason) ->
    bin(Reason).

notify(Msg) ->
    {reply, clean_reply(Msg)}.

reply(no_reply, _) -> no_reply;
reply(stop, _)     -> stop;
reply({reply, Reply}, _) ->
    {reply, clean_reply(Reply)};
reply({error, Err}, Req) ->
    error_response(Err, Req).

clean_reply(Map) when is_map(Map) ->
    maps:filter(fun(K,_) ->
                        is_atom(K) orelse is_binary(K)
                end, Map);
clean_reply(Msg) -> Msg.

process_incoming(Req, FsmPid) ->
    try sc_ws_api_jsonrpc:process_request(Req, FsmPid) of
        {error, _} =Err-> Err;
        no_reply       -> no_reply;
        {reply, Reply} -> {reply, Reply}
    catch
        error:E ->
            lager:debug("CAUGHT E=~p / Req = ~p / ~p",
                        [E, Req, erlang:get_stacktrace()]),
            no_reply
    end.


