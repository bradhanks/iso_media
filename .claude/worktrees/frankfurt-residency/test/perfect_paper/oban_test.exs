defmodule PerfectPaper.ObanTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  test "oban is configured and a job can be enqueued" do
    assert {:ok, _job} =
             Oban.insert(Oban.Job.new(%{"x" => 1}, worker: "FakeWorker", queue: :webhooks))

    assert_enqueued(worker: "FakeWorker", queue: :webhooks)
  end
end
