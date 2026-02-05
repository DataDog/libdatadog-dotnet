# Contributing to `libdatadog-dotnet`

We welcome contributions of many forms to our open source project.
However, please be aware of some of the policies below, and we *strongly* recommend reaching out before starting *any* code changes.

## External Pull Request Policies

Because of security policies in place, external pull requests have the following policies:

- **Fork Required**: You **must** create pull requests from a fork of the repository. Only approved Datadog engineers have push access.
- **Limited Testing Access**: External pull requests **cannot** run our full automated test suite.
- **Merge Process**: Pull requests from forks **cannot be merged directly**. A `libdatadog-dotnet` contributor must first create a branch from your fork and run the CI suite against it. This ensures the build and test results apply to your commit. If the CI suite passes, the contributor will then merge your PR.
