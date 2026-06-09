defmodule PerfectPaper.Teams.Manifest do
  @moduledoc """
  Builds the Teams app package. Teams requires a ZIP (manifest.json + two icons),
  not bare JSON. `:zip` needs CHARLIST filenames (`~c"..."`), not binaries.
  """
  @app_id_config_key :teams_app_id

  @doc "The Teams manifest.json as a map (bot id + messaging endpoint + personal scope)."
  @spec manifest() :: map()
  def manifest do
    app_id =
      Application.get_env(
        :perfect_paper,
        @app_id_config_key,
        "00000000-0000-0000-0000-000000000000"
      )

    %{
      "$schema" =>
        "https://developer.microsoft.com/json-schemas/teams/v1.16/MicrosoftTeams.schema.json",
      "manifestVersion" => "1.16",
      "id" => app_id,
      "version" => "1.0.0",
      "name" => %{"short" => "PerfectPaper", "full" => "PerfectPaper AI peer reviewer"},
      "description" => %{
        "short" => "AI peer review notifications",
        "full" => "Get notified when your manuscript reviews are ready."
      },
      "icons" => %{"color" => "color.png", "outline" => "outline.png"},
      "accentColor" => "#7a2e4e",
      "bots" => [
        %{
          "botId" => app_id,
          "scopes" => ["personal"],
          "supportsFiles" => false,
          "isNotificationOnly" => false
        }
      ],
      "permissions" => ["identity", "messageTeamMembers"]
    }
  end

  @doc "Builds the sideload-ready Teams app package ZIP as an in-memory binary."
  @spec package() :: binary()
  def package do
    json = Jason.encode!(manifest())
    color = File.read!(Application.app_dir(:perfect_paper, "priv/static/teams/color.png"))
    outline = File.read!(Application.app_dir(:perfect_paper, "priv/static/teams/outline.png"))

    {:ok, {_name, zip}} =
      :zip.create(
        ~c"manifest.zip",
        [
          {~c"manifest.json", json},
          {~c"color.png", color},
          {~c"outline.png", outline}
        ],
        [:memory]
      )

    zip
  end
end
