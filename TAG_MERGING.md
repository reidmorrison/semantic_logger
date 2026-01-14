# Tag Merging Behavior

This document describes how tags are merged in SemanticLogger when using instance tags (child loggers) and thread tags (tagged blocks).

## Concepts

- **Instance tags**: Tags attached to a logger instance via `logger.tagged(...)` without a block. These are permanent for that logger instance.
- **Thread tags**: Tags pushed to the thread for the duration of a `tagged { }` block. These are temporary and scoped to the block.
- **Positional tags**: Array of string tags, e.g., `tagged('request-123', 'user-456')`
- **Named tags**: Hash of key-value pairs, e.g., `tagged(user: 'alice', request_id: '123')`

## Two Merge Points (Important)

Tag merging happens at **two different points** with **different merge semantics**. Understanding this distinction is critical:

### 1. Runtime Combination (base.rb)

When a child logger calls `tagged { }` with a block, its instance tags are combined with the block's tags and pushed to thread context:

```ruby
# In base.rb:208-210
combined_tags = instance_tags + tags                              # instance first, then block
combined_named_tags = instance_named_tags.merge(named_tags)       # block wins on conflicts
```

**Purpose**: Convert instance tags to thread tags for the block duration.

**Merge order**: Block/thread tags override instance tags. This makes sense because the block provides more specific, immediate context.

### 2. Output Formatting (formatters)

When a log is rendered, formatters combine thread tags and instance tags for display:

```ruby
# In formatters (default.rb, raw.rb, etc.)
tags + instance_tags                                              # thread first, then instance
named_tags.merge(instance_named_tags)                             # instance wins on conflicts
```

**Purpose**: Render both tag sources in the final output.

**Merge order**: Instance tags override thread tags. Instance tags represent the logger's permanent identity and take precedence over transient thread context.

### Why They Differ

These operations serve different purposes:

| Aspect | Runtime (base.rb) | Output (formatters) |
|--------|-------------------|---------------------|
| When | During `tagged { }` block entry | During log rendering |
| What | Combines tags before pushing to thread | Combines tags for display |
| Winner on conflict | Block tags (more specific context) | Instance tags (permanent identity) |

The runtime merge in base.rb does **not** affect formatter output directly. The formatter always receives separate `log.tags` (thread) and `log.instance_tags` (instance) and combines them independently.

---

## Index

1. [Root Logger Cases](#1-root-logger-cases)
   - 1.1 [No context](#11-no-context)
   - 1.2 [With thread tags](#12-with-thread-tags)

2. [Child Logger Cases (No Thread Context)](#2-child-logger-cases-no-thread-context)
   - 2.1 [With instance tags](#21-with-instance-tags)

3. [Child Logger with Thread Context (Independent)](#3-child-logger-with-thread-context-independent)
   - 3.1 [Instance tags + thread tags (via root)](#31-instance-tags--thread-tags-via-root)

4. [Child Logger Inside Own Tagged Block](#4-child-logger-inside-own-tagged-block)
   - 4.1 [Instance tags + own block tags](#41-instance-tags--own-block-tags)

5. [Nested Child Loggers](#5-nested-child-loggers)
   - 5.1 [Child of child logger](#51-child-of-child-logger)
   - 5.2 [Child logger inside another child's tagged block](#52-child-logger-inside-another-childs-tagged-block)

6. [Edge Cases](#6-edge-cases)
   - 6.1 [Named tag key conflicts](#61-named-tag-key-conflicts)

---

## 1. Root Logger Cases

### 1.1 No context

```ruby
logger = SemanticLogger['MyClass']
logger.info('Hello')
```

| Field | Value |
|-------|-------|
| `log.tags` | `[]` |
| `log.named_tags` | `{}` |
| `log.instance_tags` | `[]` |
| `log.instance_named_tags` | `{}` |
| **Formatted output** | (no tags) |

### 1.2 With thread tags

```ruby
logger = SemanticLogger['MyClass']
logger.tagged('request-123', user: 'alice') do
  logger.info('Hello')
end
```

| Field | Value |
|-------|-------|
| `log.tags` | `['request-123']` |
| `log.named_tags` | `{user: 'alice'}` |
| `log.instance_tags` | `[]` |
| `log.instance_named_tags` | `{}` |
| **Formatted output** | `[request-123] {user: alice}` |

---

## 2. Child Logger Cases (No Thread Context)

### 2.1 With instance tags

```ruby
logger = SemanticLogger['MyClass']
child = logger.tagged('service-a', version: '2.0')
child.info('Hello')
```

| Field | Value |
|-------|-------|
| `log.tags` | `[]` |
| `log.named_tags` | `{}` |
| `log.instance_tags` | `['service-a']` |
| `log.instance_named_tags` | `{version: '2.0'}` |
| **Formatted output** | `[service-a] {version: 2.0}` |

---

## 3. Child Logger with Thread Context (Independent)

These cases use a child logger inside a tagged block from a **different** logger (typically root). The instance tags and thread tags are independent.

### 3.1 Instance tags + thread tags (via root)

```ruby
logger = SemanticLogger['MyClass']
child = logger.tagged('instance-pos', service: 'api')

logger.tagged('thread-pos', request_id: '123') do
  child.info('Hello')
end
```

| Field | Value |
|-------|-------|
| `log.tags` | `['thread-pos']` |
| `log.named_tags` | `{request_id: '123'}` |
| `log.instance_tags` | `['instance-pos']` |
| `log.instance_named_tags` | `{service: 'api'}` |
| **Formatted output** | `[thread-pos] [instance-pos] {request_id: 123, service: api}` |

Thread positional tags appear first, then instance positional tags. Named tags are merged as `thread_named_tags.merge(instance_named_tags)`, with instance named tags overriding thread named tags on conflict.

---

## 4. Child Logger Inside Own Tagged Block

When a child logger calls `tagged { }` on itself, its instance tags are pushed to the thread for the duration of the block. This results in **expected duplication** in the log output.

### 4.1 Instance tags + own block tags

```ruby
logger = SemanticLogger['MyClass']
child = logger.tagged('instance-pos', service: 'api')

child.tagged('block-pos', request_id: '123') do
  child.info('Hello')
end
```

| Field | Value |
|-------|-------|
| `log.tags` | `['instance-pos', 'block-pos']` |
| `log.named_tags` | `{service: 'api', request_id: '123'}` |
| `log.instance_tags` | `['instance-pos']` |
| `log.instance_named_tags` | `{service: 'api'}` |
| **Formatted output** | `[instance-pos] [block-pos] [instance-pos] {service: api, request_id: 123, service: api}` |

The instance tags appear twice: once from the thread (combined by the tagged block) and once from the instance. This is expected behavior.

**Recommendation**: Inside the block, use a logger without instance tags if you want to avoid duplication:

```ruby
child.tagged('block-pos', request_id: '123') do
  logger.info('Hello')  # Use root logger, not child
end
```

---

## 5. Nested Child Loggers

### 5.1 Child of child logger

```ruby
logger = SemanticLogger['MyClass']
child1 = logger.tagged('level-1')
child2 = child1.tagged('level-2')
child2.info('Hello')
```

| Field | Value |
|-------|-------|
| `log.tags` | `[]` |
| `log.named_tags` | `{}` |
| `log.instance_tags` | `['level-1', 'level-2']` |
| `log.instance_named_tags` | `{}` |
| **Formatted output** | `[level-1] [level-2]` |

Instance tags accumulate through the child chain.

### 5.2 Child logger inside another child's tagged block

```ruby
logger = SemanticLogger['MyClass']
child1 = logger.tagged('child1-tag', service: 'api')
child2 = logger.tagged('child2-tag', component: 'worker')

child1.tagged('block-tag', request_id: '123') do
  child2.info('Hello')  # Different child logger used inside block
end
```

| Field | Value |
|-------|-------|
| `log.tags` | `['child1-tag', 'block-tag']` |
| `log.named_tags` | `{service: 'api', request_id: '123'}` |
| `log.instance_tags` | `['child2-tag']` |
| `log.instance_named_tags` | `{component: 'worker'}` |
| **Formatted output** | `[child1-tag] [block-tag] [child2-tag] {service: api, request_id: 123, component: worker}` |

The thread tags come from child1's tagged block (which includes child1's instance tags). The instance tags come from child2.

---

## 6. Edge Cases

### 6.1 Named tag key conflicts

When the same key exists in both instance_named_tags and thread named_tags:

```ruby
logger = SemanticLogger['MyClass']
child = logger.tagged(user: 'instance-user')

child.tagged(user: 'block-user') do
  child.info('Hello')
end
```

| Field | Value |
|-------|-------|
| `log.named_tags` | `{user: 'block-user'}` |
| `log.instance_named_tags` | `{user: 'instance-user'}` |

**Question**: Which value wins in the formatted output?

In `base.rb`, the runtime combination is: `instance_named_tags.merge(named_tags)` — so **block tags win** (for pushing to thread context).

In formatters, the output combination is: `named_tags.merge(instance_named_tags)` — so **instance tags win** (permanent identity takes precedence over transient context).

---

## Summary Table

| Scenario | Thread Tags Source | Instance Tags Source | Duplication? |
|----------|-------------------|---------------------|--------------|
| Root + tagged block | Block args | None | No |
| Child + no block | None | Child creation args | No |
| Child + root's block | Root's block | Child creation args | No |
| Child + own block | Child instance + block args | Child creation args | Yes (expected) |
| Child of child | None | Accumulated from chain | No |

---

## Open Questions

None at this time.
