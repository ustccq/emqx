%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(prop_emqx_schema).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MAX_INT_TIMEOUT_MS, 4294967295).

%%--------------------------------------------------------------------
%% Helper fns
%%--------------------------------------------------------------------

parse(Value, Type) ->
    typerefl:from_string(Type, Value).

timeout_within_bounds(RawDuration) ->
    case emqx_schema:to_duration_ms(RawDuration) of
        {ok, I} when I =< ?MAX_INT_TIMEOUT_MS ->
            true;
        _ ->
            false
    end.

parses_the_same(Value, Type1, Type2) ->
    parse(Value, Type1) =:= parse(Value, Type2).

%%--------------------------------------------------------------------
%% Properties
%%--------------------------------------------------------------------

prop_duration_ms_to_str_roundtrip() ->
    ?FORALL(
        RawDuration,
        emqx_proper_types:raw_duration(),
        ?IMPLIES(
            timeout_within_bounds(RawDuration),
            begin
                {ok, Parsed0} = parse(RawDuration, emqx_schema:duration_ms()),
                Pretty = emqx_schema:duration_ms_to_str(Parsed0),
                {ok, Parsed1} = parse(Pretty, emqx_schema:duration_ms()),
                Parsed0 =:= Parsed1
            end
        )
    ).

prop_timeout_duration_refines_duration() ->
    ?FORALL(
        RawDuration,
        emqx_proper_types:raw_duration(),
        ?IMPLIES(
            timeout_within_bounds(RawDuration),
            parses_the_same(RawDuration, emqx_schema:duration(), emqx_schema:timeout_duration())
        )
    ).

prop_timeout_duration_ms_refines_duration_ms() ->
    ?FORALL(
        RawDuration,
        emqx_proper_types:raw_duration(),
        ?IMPLIES(
            timeout_within_bounds(RawDuration),
            parses_the_same(
                RawDuration, emqx_schema:duration_ms(), emqx_schema:timeout_duration_ms()
            )
        )
    ).

prop_timeout_duration_s_refines_duration_s() ->
    ?FORALL(
        RawDuration,
        emqx_proper_types:raw_duration(),
        ?IMPLIES(
            timeout_within_bounds(RawDuration),
            parses_the_same(RawDuration, emqx_schema:duration_s(), emqx_schema:timeout_duration_s())
        )
    ).

prop_timeout_duration_is_valid_for_receive_after() ->
    ?FORALL(
        RawDuration,
        emqx_proper_types:large_raw_duration(),
        ?IMPLIES(
            not timeout_within_bounds(RawDuration),
            begin
                %% we have to use the the non-strict version, because it's invalid
                {ok, Timeout} = parse(RawDuration, emqx_schema:duration()),
                Ref = make_ref(),
                timer:send_after(20, {Ref, ok}),
                ?assertError(
                    timeout_value,
                    receive
                        {Ref, ok} -> error(should_be_invalid)
                    after Timeout -> error(should_be_invalid)
                    end
                ),
                true
            end
        )
    ).
