# The GD Hub (TGH)

The GD Hub is an independent, community-maintained Geometry Dash demon-list platform. The frontend uses React + TypeScript + Vite; Supabase Auth and PostgreSQL provide identity and persistence; Row Level Security is intended to enforce permissions; GitHub Pages serves the static frontend.

## Implemented foundation

- Original dark TGH visual identity, responsive navigation, homepage, live database statistics, search, list and level detail views.
- Email/password sign-up, login, password reset, profile editing, record submission form, accepted-record view, and player submission history.
- SQL migration for profiles, protected roles, levels and creators, record submissions, moderation audit actions, reports, site settings, indexes, and RLS policies.
- GitHub Actions workflow for GitHub Pages deployment; hash routing and Vite base path target this repository.
- No fabricated level rankings or player records: disconnected/empty database states are explicit.

This is an initial implementation foundation, not yet a production-certified moderation platform. Moderator/admin dashboards, atomic review and rank-reordering operations, automated RLS tests, and end-to-end verification remain to be completed before public launch.

## Local development

Requirements: Node.js 22 and npm.

1. Copy .env.example to .env.
2. Set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY.
3. Run npm install, then npm run dev.
4. Run npm run build before deployment.

Never put a Supabase service-role or secret key in frontend code, GitHub variables, or build output. The publishable key is designed for browser use, but only with correct RLS policies.

## Supabase setup

1. Create a Supabase project.
2. Copy the project URL and publishable key from Project Settings → API into local .env.
3. Apply supabase/migrations/202610270001_initial_schema.sql in the Supabase SQL Editor or through your Supabase CLI migration workflow.
4. Configure Auth email verification and allowed redirect URLs for local development and https://solancegmd.github.io/The-GD-Hub/.
5. For GitHub Actions, add repository Variables named VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY.
6. Test registration, verification, login, password reset, profile edits, submissions, and row policies as anonymous, player, moderator, and administrator users.

### Initial administrator

Do not expose a public staff-registration form. Sign up with your owner account, find its UUID in Supabase → Authentication → Users, then run this query in the SQL Editor as the project owner, replacing the placeholder with the verified UUID:

    insert into public.user_roles (user_id, role)
    values ('YOUR-AUTH-USER-UUID', 'administrator');

No staff identities are preconfigured. Assign moderator roles only after you provide and verify the staff list. Do not commit UUIDs or credentials to the repository.

## GitHub Pages

1. Open repository Settings → Pages and choose GitHub Actions as the source.
2. Add the two repository Variables listed above.
3. Push to main or run the Deploy workflow manually in Actions.
4. Inspect the build log and verify the published URL, auth redirects, and all hash routes.

The Vite base path is /The-GD-Hub/. The workflow currently creates a package lock during CI before running npm ci because the GitHub connector cannot run npm locally; generate and commit package-lock.json from Node 22/npm on a developer machine for a fully reproducible build.

## Data model

- profiles: public username, avatar, and bio.
- user_roles: protected player/moderator/administrator roles, with no client role-write policy.
- levels and level_creators: rankable levels and multiple creators.
- record_submissions: evidence submissions and review states; a partial unique index prevents multiple active submissions for one player/level.
- moderation_actions: audit trail.
- reports: user reports and resolutions.
- site_settings: configurable list settings and draft community rules.

## Required before public launch

- [ ] Generate and commit package-lock.json.
- [ ] Apply the migration to a test Supabase project and inspect security/performance advisors.
- [ ] Implement tightly authorized transactional RPCs or Edge Functions for record decisions, rank reordering, role assignment, and audit-log writes.
- [ ] Finish moderator/admin dashboard screens and enforce action-specific permissions.
- [ ] Test direct API attempts at role escalation, self-approval, cross-user edits, duplicate submissions, and conflicting reviews.
- [ ] Finalize policy text with the owner; current rules are placeholders.
- [ ] Run npm ci && npm run build and verify the GitHub Pages deployment.

The GD Hub is an independent community project and is not affiliated with RobTop Games or any other demon-list operator.
