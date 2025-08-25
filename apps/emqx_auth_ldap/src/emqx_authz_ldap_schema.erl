%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authz_ldap_schema).

-include("emqx_auth_ldap.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-behaviour(emqx_authz_schema).

-export([
    type/0,
    fields/1,
    desc/1,
    source_refs/0,
    select_union_member/2,
    namespace/0
]).

namespace() -> "authz".

type() -> ?AUTHZ_TYPE.

fields(ldap) ->
    emqx_authz_schema:authz_common_fields(?AUTHZ_TYPE) ++
        acl_fields() ++
        [
            {query_timeout,
                ?HOCON(
                    emqx_schema:timeout_duration_ms(),
                    #{
                        desc => ?DESC(query_timeout),
                        default => <<"5s">>
                    }
                )}
        ] ++
        emqx_ldap:fields(search_options) ++
        emqx_ldap:fields(config).

acl_fields() ->
    [
        {publish_attribute, attribute_meta(publish_attribute, <<"mqttPublishTopic">>)},
        {subscribe_attribute, attribute_meta(subscribe_attribute, <<"mqttSubscriptionTopic">>)},
        {all_attribute, attribute_meta(all_attribute, <<"mqttPubSubTopic">>)},
        {acl_rule_attribute, attribute_meta(acl_rule_attribute, <<"mqttAclRule">>)}
    ].

desc(ldap) ->
    ?DESC("ldap_struct");
desc(_) ->
    undefined.

source_refs() ->
    [?R_REF(ldap)].

select_union_member(#{<<"type">> := ?AUTHZ_TYPE_BIN}, _) ->
    ?R_REF(ldap);
select_union_member(_Value, _) ->
    undefined.

%%--------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------

attribute_meta(Name, Default) ->
    ?HOCON(
        string(),
        #{
            default => Default,
            desc => ?DESC(Name)
        }
    ).
