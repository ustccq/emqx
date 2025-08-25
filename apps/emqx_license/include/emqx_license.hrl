%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-ifndef(_EMQX_LICENSE_).
-define(_EMQX_LICENSE_, true).

%% The new default ltype=community&ctype=developer license key since 5.9
%% limit=0 is encoded in the license key,
%% resolved to DEFAULT_MAX_SESSIONS_LTYPE2 at runtime.
-define(COMMUNITY_LICENSE_LOG,
    "\n"
    "=====================================================================\n"
    "You are currently using the EMQX Community License included with this software.\n"
    "Permitted Use: Free use of a single node in your internal environment.\n"
    "What Requires a Different License:\n"
    " - Clustered deployments (more than one node).\n"
    " - Commercial use in SaaS, hosted services, or embedded/resold products.\n"
    "To enable clustering or use EMQX for external commercial purposes, a commercial license is required.\n"
    "Visit https://emqx.com/apply-licenses/emqx to apply for a license.\n"
    "(Clustering for non-profit or educational purposes may qualify for a free license - please inquire via the link above)\n"
    "=====================================================================\n"
).

%% Similar to the ltype=trial&ctype=evaluation license from before 5.9
%% limit = 0 is encoded in the license key,
%% resolved to DEFAULT_MAX_SESSIONS_CTYPE10 at runtime.
-define(EVALUATION_LOG,
    "\n"
    "=============================================================================\n"
    "Using an evaluation license!\n"
    "This license is not permitted for commercial use.\n"
    "Limitations:\n"
    " - At most ~p concurrent sessions.\n"
    " - A 30-day uptime limit, must restart the node to regain the sessions quota.\n"
    "Visit https://emqx.com/apply-licenses/emqx to apply a license for:\n"
    " - Commercial use\n"
    " - Education or Non-profit use (clustered deployment, free of charge)\n"
    "=============================================================================\n"
).

-define(EXPIRY_LOG,
    "\n"
    "============================================================================\n"
    "License has been expired for ~p days.\n"
    "Visit https://emqx.com/apply-licenses/emqx?version=5 to apply a new license.\n"
    "============================================================================\n"
).

-define(TRIAL, 0).
-define(OFFICIAL, 1).
-define(COMMUNITY, 2).

-define(SMALL_CUSTOMER, 0).
-define(MEDIUM_CUSTOMER, 1).
-define(LARGE_CUSTOMER, 2).
-define(BUSINESS_CRITICAL_CUSTOMER, 3).
-define(BYOC_CUSTOMER, 4).
-define(EDUCATION_NONPROFIT_CUSTOMER, 5).
-define(EVALUATION_CUSTOMER, 10).
-define(DEVELOPER_CUSTOMER, 11).

-define(EXPIRED_DAY, -90).

-define(ERR_EXPIRED, expired).
-define(ERR_MAX_UPTIME, max_uptime_reached).

%% The default max_sessions limit for 'community' license type.
-define(DEFAULT_MAX_SESSIONS_LTYPE2, 10_000_000).

%% The default max_sessions limit for business-critical customer.
%% before dynamic_max_connections set.
-define(DEFAULT_MAX_SESSIONS_CTYPE3, 25).

%% The default max_sessions limit for the 'evaluation' customer.
-define(DEFAULT_MAX_SESSIONS_CTYPE10, 25).

%% If the max_sessions limit in a license not greater than
%% this threshold, do not allow any overshoot.
-define(NO_OVERSHOOT_SESSIONS_LIMIT, ?DEFAULT_MAX_SESSIONS_CTYPE10).

%% Allow 10% more sessions over the limit defined in the license key
-define(SESSIONS_LIMIT_OVERSHOOT_FACTOR, 1.1).

%% The default license key.
%% This default license is of single-node type and has 10M sessions limit.
%% Issued on 2025-03-02 and valid for 4 years (1460 days)
-define(DEFAULT_COMMUNITY_LICENSE_KEY, <<
    "MjIwMTExCjIKMTEKRGV2ZWxvcGVyCmNvbnRhY3RAZW1xeC5pbwpEZXZlbG9wbWVudAoyMDI1MDMwMgoxNDYwCjAK."
    "MEUCIQCCyEkOUIFDop1/69mU3UoAGOTraIh+jYn5ZineZbZq+gIgIlkVl0h0aqajY8QtkxrXbdN3N8a3rPPluBxt+d2o3lM="
>>).

%% The default evaluation license key.
%% This evaluation license is of single-node type and has 25 concurrent sessions limit.
%% Issued on 2025-03-02 and valid for 4 years (1460 days)
-define(DEFAULT_EVALUATION_LICENSE_KEY, <<
    "MjIwMTExCjAKMTAKRXZhbHVhdGlvbgpjb250YWN0QGVtcXguaW8KdHJpYWwKMjAyNTAzMDIKMTQ2MAowCg==."
    "MEYCIQDWjM8kgaaNlLWQCN/uwF+phG7Z1/oqUeYGKBQXRZjnNQIhALfCWmM9o3q7eEvuYZNAnp12vWZeaxVxKT4XFuX6Z+rp"
>>).

-endif.
