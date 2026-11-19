# MapAutomation test fixtures

The fixture maps in these tests are built programmatically (`FixtureMap`
in `Tests/MapAutomationTests/FixtureMap.swift`) and written to temp
directories at run time — no binary fixtures are checked in. Every test
cleans its directories up in `defer`.
