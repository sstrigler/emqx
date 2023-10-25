%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-ifndef(EMQX_AUTH_LDAP_HRL).
-define(EMQX_AUTH_LDAP_HRL, true).

-define(AUTHZ_TYPE, ldap).
-define(AUTHZ_TYPE_BIN, <<"ldap">>).

-define(AUTHN_MECHANISM, password_based).
-define(AUTHN_MECHANISM_BIN, <<"password_based">>).

-define(AUTHN_BACKEND, ldap).
-define(AUTHN_BACKEND_BIN, <<"ldap">>).

-define(AUTHN_BACKEND_BIND, ldap_bind).
-define(AUTHN_BACKEND_BIND_BIN, <<"ldap_bind">>).

-define(AUTHN_TYPE, {?AUTHN_MECHANISM, ?AUTHN_BACKEND}).
-define(AUTHN_TYPE_BIND, {?AUTHN_MECHANISM, ?AUTHN_BACKEND_BIND}).

-endif.
