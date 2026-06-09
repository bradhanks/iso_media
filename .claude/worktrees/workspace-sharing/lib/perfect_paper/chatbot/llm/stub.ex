defmodule PerfectPaper.Chatbot.LLM.Stub do
  @moduledoc """
  In-process stub adapter for the LLM behaviour.

  Returns a fixed assistant response with no external calls.
  Used in test and development environments.
  """
  @behaviour PerfectPaper.Chatbot.LLM

  @doc "Returns a deterministic stub response regardless of message history."
  @spec complete([%{role: atom(), content: String.t()}], keyword()) ::
          {:ok, %{role: :assistant, content: String.t()}} | {:error, term()}
  def complete(_messages, _opts \\ []) do
    {:ok, %{role: :assistant, content: "This is a stubbed assistant response."}}
  end

  @doc """
  Returns a deterministic stubbed review, varied by processing level (`opts[:level]`):
  `:preview` is a brief, single-comment first pass; any other level is a deeper,
  multi-comment read. The composed `system` prompt is ignored by the stub.
  """
  @spec review(String.t(), String.t(), keyword()) ::
          {:ok, %{overall_feedback: String.t(), comments: [map()]}}
  def review(_text, _system, opts) do
    case Keyword.get(opts, :level) do
      :preview ->
        {:ok,
         %{
           overall_feedback:
             "Preview: a quick first pass to show what a full review surfaces. Use a credit " <>
               "for the complete, in-depth review.",
           comments: [
             %{
               position: 1,
               category: "clarity",
               suggestion: "Lead the abstract with your finding",
               original_text: nil,
               explanation: nil
             }
           ]
         }}

      _ ->
        {:ok,
         %{
           overall_feedback:
             "A thorough read across methods, claims, figures, and consistency. The most " <>
               "consequential items are the causal-adjustment strategy and the reliability of " <>
               "the derived scales; addressing those will materially strengthen the submission.",
           comments: [
             %{
               position: 1,
               category: "methods",
               suggestion: "Make the causal-adjustment set explicit",
               original_text: "directed acyclic graphs encoded a priori knowledge",
               explanation:
                 "Name each backdoor path you are closing and the assumption behind every included covariate."
             },
             %{
               position: 2,
               category: "statistics",
               suggestion: "Report reliability for the derived scales",
               original_text: "three factor-derived scales",
               explanation: "Add Cronbach's alpha (or McDonald's omega) and the factor loadings."
             },
             %{
               position: 3,
               category: "data",
               suggestion: "Reconcile the subgroup counts",
               original_text: nil,
               explanation: "The subgroup totals do not add up to the figures reported earlier."
             },
             %{
               position: 4,
               category: "claims",
               suggestion: "Soften unsupported causal language",
               original_text: "drive vaccine refusal",
               explanation: "The design supports association, not population-level causation."
             }
           ]
         }}
    end
  end
end
