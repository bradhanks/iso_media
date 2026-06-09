defmodule PerfectPaperWeb.DemoLiveTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # Byte index of the first occurrence of `needle` in `html` (for order checks).
  defp index_of(html, needle), do: byte_size(hd(String.split(html, needle)))

  describe "GET /demo (hub)" do
    test "lists the demos publicly, with links into each", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/demo")

      assert html =~ "Interactive demos"
      assert html =~ "Review lifecycle"
      assert html =~ ~p"/demo/review"
      assert html =~ ~p"/demo/billing"
      assert html =~ ~p"/demo/earn"
    end
  end

  describe "GET /demo/review — the lifecycle" do
    test "mounts publicly at the Feedback step with the document + feedback", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/demo/review")

      assert html =~ "Rural–Urban Divides and Cultural Dynamics in Vaccine Hesitancy"
      assert html =~ "Overall feedback"
      assert html =~ "Causal adjustment is underspecified in §3.2"
      assert html =~ "7 open"

      for label <- ~w(Submit Review Feedback Discuss Resolve) do
        assert html =~ label
      end
    end

    test "the step rail walks Submit → Review → Resolve", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo/review")

      assert view |> element(~s(button[phx-value-step="submit"])) |> render_click() =~
               "Drop your manuscript"

      assert view |> element(~s(button[phx-value-step="review"])) |> render_click() =~
               "Reading §3.2"

      assert view |> element(~s(button[phx-value-step="resolve"])) |> render_click() =~
               "Submission-ready"
    end

    test "detailed feedback sorts by relevance or document position", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/demo/review")

      relevance_first = "Causal adjustment is underspecified"
      # The "Define ...rural... and ...urban... operationally" comment sits first
      # in the document (position 1) but is ranked lower by relevance.
      position_first = "operationally"

      # Default is by relevance: the #1 comment leads.
      assert index_of(html, relevance_first) < index_of(html, position_first)

      by_position =
        view
        |> element(~s(button[phx-click="sort_feedback"][phx-value-sort="position"]))
        |> render_click()

      # By position: the document-order-first comment now leads.
      assert index_of(by_position, position_first) < index_of(by_position, relevance_first)
      # But its identity number is stable — still numbered by relevance.
      assert by_position =~ "Causal adjustment is underspecified"
    end

    test "addressing a comment updates its status and the open count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo/review")

      html =
        view |> element(~s(button[phx-click="address"][phx-value-id="1"])) |> render_click()

      assert html =~ "Addressed"
      assert html =~ "6 open"
    end

    test "dismissing a comment minimizes it to a single line", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo/review")

      html =
        view |> element(~s(button[phx-click="dismiss"][phx-value-id="1"])) |> render_click()

      refute html =~ "State each backdoor path you are closing"
      assert html =~ "Causal adjustment is underspecified in §3.2"
      assert html =~ ~s(phx-click="undo")
    end

    test "a person can reply and Ask PerfectPaper adds a chatbot reply", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/demo/review")
      assert html =~ "R. Mehta (co-author)"

      replied =
        view
        |> form("#reply-form-3", %{comment_id: "3", body: "Fixing Table 4 now."})
        |> render_submit()

      assert replied =~ "Fixing Table 4 now."

      asked =
        view
        |> element(~s(button[phx-click="ask_bot"][phx-value-comment_id="3"]))
        |> render_click()

      assert asked =~ "I can draft a revision and cite the relevant section"
    end

    test "archiving a comment moves it to the Archived section and restoring brings it back",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/demo/review")
      refute html =~ "Archived"

      archived =
        view |> element(~s(button[phx-click="archive"][phx-value-id="1"])) |> render_click()

      assert archived =~ "Archived"
      refute archived =~ "State each backdoor path you are closing"

      restored =
        view |> element(~s(button[phx-click="unarchive"][phx-value-id="1"])) |> render_click()

      assert restored =~ "State each backdoor path you are closing"
    end

    test "the Discuss step opens the chat and the bot answers a question", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo/review")

      discuss = view |> element(~s(button[phx-value-step="discuss"])) |> render_click()
      assert discuss =~ "Ask about this review"

      answered =
        view
        |> form(~s(form[phx-submit="send"]), %{message: "What should I fix first?"})
        |> render_submit()

      assert answered =~ "What should I fix first?"
      assert answered =~ "make the §3.2 adjustment set explicit"
    end

    # ── Allowlist guard: goto_step must not call String.to_existing_atom on
    # unvalidated user input. The guard `when step in @valid_steps` ensures the
    # conversion only runs for known step names.

    test "goto_step with a valid step name navigates to that step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo/review")

      html = view |> render_hook("goto_step", %{"step" => "submit"})
      assert html =~ "Drop your manuscript"
    end

    test "goto_step with an invalid value does not crash the process", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo/review")

      # "__struct__" is a binary that String.to_existing_atom would raise on
      # if it were not guarded. The catch-all clause must keep the process alive.
      html = view |> render_hook("goto_step", %{"step" => "__struct__"})
      # The LiveView remains on the current step (feedback) and does not crash.
      assert html =~ "Causal adjustment is underspecified in §3.2"
    end
  end

  describe "GET /demo/history" do
    test "lists sample reviews linking into the lifecycle", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/demo/history")

      assert html =~ "Your reviews"
      assert html =~ "Rural–Urban Divides and Cultural Dynamics in Vaccine Hesitancy"
      assert html =~ "Complete"
      assert html =~ ~p"/demo/review"
    end
  end

  describe "GET /demo/billing" do
    test "renders the plans and a free current-plan summary", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/demo/billing")

      assert html =~ "Monthly plans"
      assert html =~ "free previews"
      assert html =~ "Starter"
    end
  end

  describe "GET /demo/earn" do
    test "shows the balance, referral link, and ledger", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/demo/earn")

      assert html =~ "Credit balance"
      assert html =~ "Invite colleagues"
      assert html =~ "perfectpaper.ink/r/"
    end
  end
end
