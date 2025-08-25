%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-ifndef(EMQX_AUTHN_HRL).
-define(EMQX_AUTHN_HRL, true).

-include("emqx_authn_chains.hrl").
-include_lib("emqx/include/emqx_placeholder.hrl").

-define(AUTHN, emqx_authn_chains).

%% has to be the same as the root field name defined in emqx_schema
-define(CONF_NS, ?EMQX_AUTHENTICATION_CONFIG_ROOT_NAME).
-define(CONF_NS_ATOM, ?EMQX_AUTHENTICATION_CONFIG_ROOT_NAME_ATOM).
-define(CONF_NS_BINARY, ?EMQX_AUTHENTICATION_CONFIG_ROOT_NAME_BINARY).

-define(CONF_SETTINGS_NS_ATOM, authentication_settings).

-type authenticator_id() :: binary().

-define(AUTHN_RESOURCE_GROUP, <<"authn">>).

%% VAR_NS_CLIENT_ATTRS is added here because it can be initialized before authn.
%% NOTE: authn return may add more to (or even overwrite) client_attrs.
-define(AUTHN_DEFAULT_ALLOWED_VARS, [
    ?VAR_USERNAME,
    ?VAR_CLIENTID,
    ?VAR_PASSWORD,
    ?VAR_PEERHOST,
    ?VAR_PEERPORT,
    ?VAR_CERT_SUBJECT,
    ?VAR_CERT_CN_NAME,
    ?VAR_CERT_PEM,
    ?VAR_ZONE,
    ?VAR_NS_CLIENT_ATTRS,
    ?VAR_LISTENER
]).

-define(AUTHN_CACHE, emqx_authn_cache).

-endif.
