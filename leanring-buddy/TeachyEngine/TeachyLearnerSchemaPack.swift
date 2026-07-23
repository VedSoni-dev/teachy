//
//  TeachyLearnerSchemaPack.swift
//  leanring-buddy
//
//  The teachy-learner-v1 schema-pack, embedded verbatim as a string so the
//  provisioner can install it without depending on a bundled resource file.
//
//  It is kept BYTE-IDENTICAL to learner-brain/teachy-learner-v1.yaml (the
//  source of truth, validated against gbrain's `schema validate`). If you edit
//  one, edit the other. gbrain parses packs with a hand-rolled mini-YAML parser
//  that rejects block/folded scalars, anchors, aliases, and tags — keep this to
//  plain `key: value`, 2-space maps, `- ` sequences, flow arrays, and comments.
//

import Foundation

enum TeachyLearnerSchemaPack {
    /// Slug used for the pack directory + `schema use <name>`.
    static let name = "teachy-learner-v1"

    static let yaml = #"""
# teachy-learner-v1 — the "MyChart for education" schema-pack
#
# This is the learner-record data model. It reshapes gbrain (a knowledge-worker
# second brain) into a longitudinal, evidence-cited record of one human learner:
# every skill, the exact moment that proved it, every misconception, every review.

api_version: gbrain-schema-pack-v1
name: teachy-learner-v1
version: 1.0.0
description: "Longitudinal, evidence-cited record of a single human learner. Skills backed by the moments that proved them, misconceptions tracked as durable contradictions, sessions/teachbacks/reviews on a timeline. MyChart, for learning."
author: Teachy
gbrain_min_version: 0.42.0
extends: null
borrow_from: []
takes_kinds:
  - fact
  - hunch

page_types:
  - name: learner
    primitive: entity
    path_prefixes:
      - learner/
    aliases:
      - student
      - user
    extractable: false
    expert_routing: false

  - name: skill
    primitive: concept
    path_prefixes:
      - skills/
    aliases:
      - competency
      - ability
    extractable: false
    expert_routing: false

  - name: concept
    primitive: concept
    path_prefixes:
      - concepts/
    aliases:
      - idea
      - topic
    extractable: false
    expert_routing: false

  - name: goal
    primitive: concept
    path_prefixes:
      - goals/
    aliases:
      - outcome
      - done-when
    extractable: false
    expert_routing: false

  - name: course
    primitive: entity
    path_prefixes:
      - courses/
    aliases:
      - track
      - lesson
    extractable: false
    expert_routing: false

  - name: session
    primitive: temporal
    path_prefixes:
      - sessions/
    aliases:
      - lesson-session
      - sitting
    extractable: false
    expert_routing: false

  - name: teachback
    primitive: temporal
    path_prefixes:
      - teachbacks/
    aliases:
      - explanation
      - teach-back
    extractable: false
    expert_routing: false

  - name: review
    primitive: temporal
    path_prefixes:
      - reviews/
    aliases:
      - retention-check
      - recall
    extractable: false
    expert_routing: false

  - name: misconception
    primitive: annotation
    path_prefixes:
      - misconceptions/
    aliases:
      - error-model
      - contradiction
    extractable: false
    expert_routing: false

  - name: artifact
    primitive: media
    path_prefixes:
      - artifacts/
    aliases:
      - portfolio-item
      - build
    extractable: false
    expert_routing: false

  - name: note
    primitive: concept
    path_prefixes:
      - notes/
    aliases: []
    extractable: false
    expert_routing: false

link_types:
  - name: demonstrates
    inverse: demonstrated_by
  - name: checks
    inverse: checked_by
  - name: covers
    inverse: covered_by
  - name: targets
    inverse: targeted_by
  - name: requires
    inverse: prerequisite_of
  - name: transfers_to
    inverse: transfers_from
  - name: contradicts
    inverse: contradicted_by
  - name: evidences
    inverse: evidenced_by
  - name: part_of
    inverse: has_part
  - name: about
    inverse: discussed_in

frontmatter_links:
  - page_type: teachback
    fields: [skill]
    link_type: demonstrates
  - page_type: teachback
    fields: [concept]
    link_type: about
  - page_type: review
    fields: [skill]
    link_type: checks
  - page_type: session
    fields: [covers]
    link_type: covers
  - page_type: session
    fields: [goal]
    link_type: targets
  - page_type: session
    fields: [course]
    link_type: part_of
  - page_type: skill
    fields: [prerequisites]
    link_type: requires
  - page_type: skill
    fields: [transfers_to]
    link_type: transfers_to
  - page_type: misconception
    fields: [skill, concept]
    link_type: contradicts
  - page_type: artifact
    fields: [evidences]
    link_type: evidences
  - page_type: goal
    fields: [course]
    link_type: part_of

filing_rules:
  - kind: skill
    directory: skills/
    description: One page per capability the learner is building.
  - kind: session
    directory: sessions/
    description: One page per learning sitting; the timeline's unit.
  - kind: teachback
    directory: teachbacks/
    description: One page per teach-back attempt, with the explanation verbatim.
  - kind: review
    directory: reviews/
    description: One page per spaced-repetition review outcome.
  - kind: misconception
    directory: misconceptions/
    description: One page per durable wrong model; status open|resolved.
  - kind: artifact
    directory: artifacts/
    description: One page per built thing; the portfolio.
"""#
}
