%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authn).

-behaviour(emqx_config_backup).

-export([
    fill_defaults/1,
    %% for telemetry information
    get_enabled_authns/0,

    register_provider/2,
    deregister_provider/1
]).

-export([merge_config/1, merge_config_local/2, import_config/2]).

-include("emqx_authn.hrl").

fill_defaults(Config) ->
    emqx_schema:fill_defaults_for_type(emqx_authn_schema:authenticator_type(), Config).

-spec get_enabled_authns() ->
    #{
        authenticators => [authenticator_id()],
        overridden_listeners => #{authenticator_id() => pos_integer()}
    }.
get_enabled_authns() ->
    %% at the moment of writing, `emqx_authn_chains:list_chains/0'
    %% result is always wrapped in `{ok, _}', and it cannot return any
    %% error values.
    {ok, Chains} = emqx_authn_chains:list_chains(),
    AuthnTypes = lists:usort([
        Type
     || #{authenticators := As} <- Chains,
        #{id := Type, enable := true} <- As
    ]),
    OverriddenListeners =
        lists:foldl(
            fun
                (#{name := ?GLOBAL}, Acc) ->
                    Acc;
                (#{authenticators := As}, Acc) ->
                    lists:foldl(fun tally_authenticators/2, Acc, As)
            end,
            #{},
            Chains
        ),
    #{
        authenticators => AuthnTypes,
        overridden_listeners => OverriddenListeners
    }.

tally_authenticators(#{id := AuthenticatorName}, Acc) ->
    maps:update_with(AuthenticatorName, fun(N) -> N + 1 end, 1, Acc).

register_provider(ProviderType, ProviderModule) ->
    ok = ?AUTHN:register_provider(ProviderType, ProviderModule).

deregister_provider(ProviderType) ->
    ok = ?AUTHN:deregister_provider(ProviderType).

%%------------------------------------------------------------------------------
%% Data backup
%%------------------------------------------------------------------------------

-define(IMPORT_OPTS, #{override_to => cluster}).

import_config(_Namespace, RawConf) ->
    AuthnList = authn_list(maps:get(?CONF_NS_BINARY, RawConf, [])),
    OldAuthnList = emqx:get_raw_config([?CONF_NS_BINARY], []),
    MergedAuthnList = emqx_utils:merge_lists(
        OldAuthnList, AuthnList, fun emqx_authn_chains:authenticator_id/1
    ),
    case emqx_conf:update([?CONF_NS_ATOM], MergedAuthnList, ?IMPORT_OPTS) of
        {ok, #{raw_config := NewRawConf}} ->
            {ok, #{root_key => ?CONF_NS_ATOM, changed => changed_paths(OldAuthnList, NewRawConf)}};
        Error ->
            {error, #{root_key => ?CONF_NS_ATOM, reason => Error}}
    end.

changed_paths(OldAuthnList, NewAuthnList) ->
    KeyFun = fun emqx_authn_chains:authenticator_id/1,
    Changed = maps:get(changed, emqx_utils:diff_lists(NewAuthnList, OldAuthnList, KeyFun)),
    [[?CONF_NS_BINARY, emqx_authn_chains:authenticator_id(OldAuthn)] || {OldAuthn, _} <- Changed].

authn_list(Authn) when is_list(Authn) ->
    Authn;
authn_list(Authn) when is_map(Authn) ->
    [Authn].

merge_config(AuthNs) ->
    emqx_authn_api:update_config([?CONF_NS_ATOM], {merge_authenticators, AuthNs}).

merge_config_local(AuthNs, Opts) ->
    emqx:update_config([?CONF_NS_ATOM], {merge_authenticators, AuthNs}, Opts).
