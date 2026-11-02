# Changelog

## [1.11.0](https://github.com/udondan/priority-boarding/compare/v1.10.1...v1.11.0) (2026-11-02)


### Features

* let pull requests from forks take part in the queue ([#44](https://github.com/udondan/priority-boarding/issues/44)) ([1e39c57](https://github.com/udondan/priority-boarding/commit/1e39c57e561e52dca0876d601e1759d688d1a343))


### Bug Fixes

* fail at once without contents: write and support Dependabot pull requests ([#46](https://github.com/udondan/priority-boarding/issues/46)) ([80168be](https://github.com/udondan/priority-boarding/commit/80168be50cfff37eb6b56ddc9b40886d93561844))
* keep the commit status of a fork's run when workflow_run starts again for its later jobs ([#50](https://github.com/udondan/priority-boarding/issues/50)) ([8b57e0f](https://github.com/udondan/priority-boarding/commit/8b57e0fdb4c21813f11331b3a7e93fb7d3e4ff65))
* support pull_request_target workflows ([#47](https://github.com/udondan/priority-boarding/issues/47)) ([9245cf0](https://github.com/udondan/priority-boarding/commit/9245cf0c3ba16c3c5f7517ffcbf72f92752293a7))


### Dependencies

* **deps:** update jdx/mise-action action to v5 ([#48](https://github.com/udondan/priority-boarding/issues/48)) ([7a25ab0](https://github.com/udondan/priority-boarding/commit/7a25ab08b93e0b115a1d0b5004e16197db0b76e8))

## [1.10.1](https://github.com/udondan/priority-boarding/compare/v1.10.0...v1.10.1) (2026-11-01)


### Miscellaneous Chores

* release 1.10.1 ([#42](https://github.com/udondan/priority-boarding/issues/42)) ([d488163](https://github.com/udondan/priority-boarding/commit/d48816310df8c0d9c12d3fa4bc6556b6a8fa1b81))

## [1.10.0](https://github.com/udondan/priority-boarding/compare/v1.9.0...v1.10.0) (2026-11-01)


### Features

* prioritize pull requests labelled urgent in the reusable workflow ([#38](https://github.com/udondan/priority-boarding/issues/38)) ([2b53668](https://github.com/udondan/priority-boarding/commit/2b53668b9ff7493d8ddf28d9ae3b59e33b0d916f))
* rename the action to priority-boarding ([#40](https://github.com/udondan/priority-boarding/issues/40)) ([a4fcbf6](https://github.com/udondan/priority-boarding/commit/a4fcbf6954b947751137d78a4e27ac7b3b4689f6))


### Bug Fixes

* release the turn when the holder's pull request has a failed required check ([#33](https://github.com/udondan/priority-boarding/issues/33)) ([b8d9fce](https://github.com/udondan/priority-boarding/commit/b8d9fce972a70b70d5501d3249267caf4f2899ce))
* set the error status when a waiting run is cancelled ([#32](https://github.com/udondan/priority-boarding/issues/32)) ([61ed5bb](https://github.com/udondan/priority-boarding/commit/61ed5bb9bc9ee7e840538ea7e66acf0c4954c543))

## [1.9.0](https://github.com/udondan/wait-for-turn/compare/v1.8.0...v1.9.0) (2026-10-31)


### Features

* don't wait for tested pull requests that are behind, optionally rebase them ([#28](https://github.com/udondan/wait-for-turn/issues/28)) ([697a84f](https://github.com/udondan/wait-for-turn/commit/697a84fc4c8d75f99cd8f7e7f0d3f5fbdbb5078d))

## [1.8.0](https://github.com/udondan/wait-for-turn/compare/v1.7.1...v1.8.0) (2026-10-31)


### Features

* add the wait job as a reusable workflow ([#26](https://github.com/udondan/wait-for-turn/issues/26)) ([126172c](https://github.com/udondan/wait-for-turn/commit/126172cdf5393d7fcfe1aa7500f8721ffc87377a))

## [1.7.1](https://github.com/udondan/wait-for-turn/compare/v1.7.0...v1.7.1) (2026-10-30)


### Bug Fixes

* fail a waiting run when its pull request has a newer commit ([#24](https://github.com/udondan/wait-for-turn/issues/24)) ([1e1e4b5](https://github.com/udondan/wait-for-turn/commit/1e1e4b5b34b950580254cf3aea6e0d26ecf1c3bc))

## [1.7.0](https://github.com/udondan/wait-for-turn/compare/v1.6.0...v1.7.0) (2026-10-30)


### Features

* show queue position as commit status ([#14](https://github.com/udondan/wait-for-turn/issues/14)) ([52b9cf1](https://github.com/udondan/wait-for-turn/commit/52b9cf1587343e9ceec34e8a868728db1219a5da))
