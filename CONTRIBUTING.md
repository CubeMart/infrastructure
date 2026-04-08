# Contributing to CubeMart

Thanks for contributing to CubeMart.

## Branch Flow

- `feature/*` branches are used for individual tasks and fixes.
- `dev` is the active development branch.
- `test` is used for integration and verification.
- `main` is the production-ready branch.

Recommended promotion path:

`feature/*` -> `dev` -> `test` -> `main`

## Getting Started

1. Start from the latest `dev` branch.
2. Create a branch for your work, for example `feature/auth-login`.
3. Make focused changes for one task.
4. Commit with a clear message.
5. Push your branch and open a pull request into `dev`.

## Commit Style

Use short, action-oriented commit messages. Good examples:

- `Add frontend login validation`
- `Fix checkout currency formatting`
- `Update shipping README commands`
- `Add PR template`

Try to keep each commit focused on one logical change.

## Pull Request Flow

1. Push your branch to GitHub.
2. Open a pull request into `dev`.
3. Add a short summary of what changed and why.
4. Respond to review feedback if needed.
5. Merge into `dev` after approval.
6. Promote `dev` to `test`, and `test` to `main`, when the changes are ready.

## Pull Request Checklist

- [ ] Branch is created from `dev`
- [ ] Change is scoped to one task or fix
- [ ] Commit messages are clear
- [ ] Relevant documentation is updated if needed
- [ ] Pull request targets `dev`

## Collaboration Notes

- Do not push directly to `main`.
- Prefer pull requests over direct branch commits.
- Keep pull requests small and reviewable.
- Make sure your Git commit email matches your GitHub account email so contributions appear on your profile.
