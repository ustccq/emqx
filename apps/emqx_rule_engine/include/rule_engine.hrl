%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-define(APP, emqx_rule_engine).

-define(KV_TAB, '@rule_engine_db').

-define(RES_SEP, <<":">>).
-define(NS_SEG, <<"ns">>).

-type option(T) :: T | undefined.

-type rule_id() :: binary().
-type rule_name() :: binary().

-type mf() :: {Module :: atom(), Fun :: atom()}.

-type hook() :: atom() | 'any'.
-type topic() :: binary().

-type selected_data() :: map().
-type envs() :: map().

-type builtin_action_func() :: republish | console.
-type builtin_action_module() :: emqx_rule_actions.
-type bridge_channel_id() :: binary().
-type action_fun_args() :: map().

-type action() ::
    #{
        mod := builtin_action_module() | module(),
        func := builtin_action_func() | atom(),
        args => action_fun_args()
    }
    | bridge_channel_id()
    | {bridge_v2, emqx_bridge_v2:bridge_v2_type(), emqx_bridge_v2:bridge_v2_name()}
    | {bridge, emqx_utils_maps:config_key(), emqx_utils_maps:config_key(), bridge_channel_id()}.

%% Arithmetic operators
-define(is_arith(Op),
    (Op =:= '+' orelse
        Op =:= '-' orelse
        Op =:= '*' orelse
        Op =:= '/' orelse
        Op =:= 'div' orelse
        Op =:= 'mod')
).

%% Compare operators
-define(is_comp(Op),
    (Op =:= '=' orelse
        Op =:= '=~' orelse
        Op =:= '>' orelse
        Op =:= '<' orelse
        Op =:= '<=' orelse
        Op =:= '>=' orelse
        Op =:= '<>' orelse
        Op =:= '!=')
).

%% Logical operators
-define(is_logical(Op), (Op =:= 'and' orelse Op =:= 'or')).

-define(RAISE(EXP, ERROR),
    ?RAISE(EXP, _ = do_nothing, ERROR)
).

-define(RAISE_BAD_SQL(Detail), throw(Detail)).

-define(RAISE(EXP, EXP_ON_FAIL, ERROR),
    fun() ->
        try
            (EXP)
        catch
            EXCLASS:EXCPTION:ST ->
                EXP_ON_FAIL,
                throw(ERROR)
        end
    end()
).

%% Tables
-define(RULE_TAB, emqx_rule_engine).
-define(RULE_TOPIC_INDEX, emqx_rule_engine_topic_index).

%% Allowed sql function provider modules
-define(DEFAULT_SQL_FUNC_PROVIDER, emqx_rule_funcs).
-define(IS_VALID_SQL_FUNC_PROVIDER_MODULE_NAME(Name),
    (case Name of
        <<"emqx_rule_funcs", _/binary>> ->
            true;
        <<"EmqxRuleFuncs", _/binary>> ->
            true;
        _ ->
            false
    end)
).

-define(ROOT_KEY, rule_engine).
-define(ROOT_KEY_BIN, <<"rule_engine">>).
-define(KEY_PATH, [?ROOT_KEY, rules]).
-define(RULE_PATH(RULE), [?ROOT_KEY, rules, RULE]).
-define(TAG, "RULE").
