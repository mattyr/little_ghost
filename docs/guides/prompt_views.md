# Prompts as Views

A short prompt fits nicely inside an Agent class. As the instructions grow, move them into a **prompt view**: an ERB file that LittleGhost finds and renders for the Agent.

This keeps the Agent definition focused. It also gives shared instructions and application values a natural home.

## Start with the inline prompt

The Agent from Getting Started keeps its first instruction close to the model:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly and concisely."
end
```

Inline prompts are a good fit while the whole instruction is one thought.

## Move a growing prompt into a view

Remove `system_prompt` from the class:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  tools HelpCenterLookupTool, OrderStatusTool
end
```

Then create `app/prompts/customer_support/system.erb`:

```erb
You help customers understand their orders and account.

Answer clearly and concisely.
Never invent company guidance. Check the help center when policy matters.
Use the order status tool before making a claim about a private order.
```

That is enough. `CustomerSupportAgent` becomes `customer_support`, so LittleGhost looks for `customer_support/system.erb` under `app/prompts`.

The prompt is still a system instruction sent to the selected model provider. Keeping it in a view improves organization; it does not keep the content inside your process.

## Give the view application values

Use `prompt_local` for a value the application owns:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  prompt_local :company_name, "Northstar"
end
```

The local is available by name in the view:

```erb
You are a customer support agent for <%= company_name %>.
Answer clearly and concisely.
```

A block can resolve a trusted value for each Agent instance. Add it to the Agent class too:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  prompt_local(:policy_version) { SupportPolicy.current_version }
end
```

Prompt views also receive `invocation`, `run`, and `agent`. Reach for those when the instruction truly depends on the current request. Keep user wording in the caller message unless you deliberately want it inside the system instruction.

Every rendered value may be sent to the model provider. Pass only data that belongs in the prompt.

## Share a small partial

Partials keep repeated instructions in one place. Create `app/prompts/shared/_voice.erb`:

```erb
Use a warm, direct voice for <%= company_name %>.
Prefer one clear next step over a long list of possibilities.
```

Render it from the Agent's system view:

```erb
You are a customer support agent for <%= company_name %>.

<%= partial "shared/voice", locals: {company_name: company_name} %>
```

The underscore marks a partial. Its locals are explicit, so it does not quietly inherit everything available to the parent view.

## Choose a different template path

Most named Agents can rely on their conventional path. Use `system_template` when a class should read a differently named view:

```ruby
class BillingSupportAgent < LittleGhost::Agent
  system_template "customer_support/billing"
end
```

LittleGhost chooses one prompt source in this order:

1. An inline `system_prompt`
2. An explicit `system_template`
3. The Agent's conventional `system.erb` view

Applications can add prompt lookup roots through `Configuration#prompt_paths`. Earlier roots win, which is useful when one trusted application layer overrides a shared prompt package.

## Treat views as application code

Prompt views run as ERB inside the Ruby process. They can call Ruby, so keep every prompt directory application-controlled and non-user-writable. Never turn a request or model-supplied path into a prompt root.

`TrustedPath` exists for the uncommon case where trusted application code selects a request-specific root. It records a trust decision; it does not make an untrusted directory safe.

## Build request-specific input in a Workflow

A prompt view defines reusable instructions for one Agent. A Workflow may still build request-specific input for that Agent:

```ruby
invoke CustomerSupportAgent, input: <<~MESSAGE
  #{input.text}

  Verified research:
  #{research}
MESSAGE
```

The Workflow is composing this request. `CustomerSupportAgent` still receives its own system prompt view when it runs.

Continue with [Tools](tools.md) to give those Agents application capabilities
while keeping model input, trusted context, and delegated sandbox operations
distinct.
