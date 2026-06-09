defmodule PerfectPaper.Billing.InvoiceTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Billing.Invoice

  test "issue_changeset requires the core billed fields" do
    cs = Invoice.issue_changeset(%Invoice{}, %{})
    refute cs.valid?
  end
end
