defmodule PerfectPaperWeb.Scim.DiscoveryController do
  @moduledoc "Static SCIM discovery documents (ServiceProviderConfig, ResourceTypes, Schemas)."
  use PerfectPaperWeb, :controller

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"

  @spec service_provider_config(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def service_provider_config(conn, _params) do
    json(conn, %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"],
      "patch" => %{"supported" => true},
      "filter" => %{"supported" => true, "maxResults" => 100},
      "bulk" => %{"supported" => false, "maxOperations" => 0, "maxPayloadSize" => 0},
      "sort" => %{"supported" => false},
      "etag" => %{"supported" => false},
      "changePassword" => %{"supported" => false},
      "authenticationSchemes" => [
        %{
          "type" => "oauthbearertoken",
          "name" => "OAuth Bearer Token",
          "description" => "Authentication via the per-org SCIM bearer token"
        }
      ]
    })
  end

  @spec resource_types(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resource_types(conn, _params) do
    json(conn, %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
      "totalResults" => 2,
      "Resources" => [
        %{
          "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"],
          "id" => "User",
          "name" => "User",
          "endpoint" => "/Users",
          "schema" => @user_schema
        },
        %{
          "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"],
          "id" => "Group",
          "name" => "Group",
          "endpoint" => "/Groups",
          "schema" => @group_schema
        }
      ]
    })
  end

  @spec schemas(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def schemas(conn, _params) do
    json(conn, %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
      "totalResults" => 2,
      "Resources" => [
        %{
          "id" => @user_schema,
          "name" => "User",
          "attributes" => [
            %{"name" => "userName", "type" => "string", "required" => true},
            %{"name" => "active", "type" => "boolean", "required" => false},
            %{"name" => "externalId", "type" => "string", "required" => false}
          ]
        },
        %{
          "id" => @group_schema,
          "name" => "Group",
          "attributes" => [
            %{"name" => "displayName", "type" => "string", "required" => true},
            %{
              "name" => "members",
              "type" => "complex",
              "multiValued" => true,
              "required" => false
            }
          ]
        }
      ]
    })
  end
end
