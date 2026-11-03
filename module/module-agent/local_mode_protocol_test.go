package main

import "testing"

func TestLocalModeCommandCrossLanguageProof(t *testing.T) {
	cmd := localModeCommand{Version: 1, AgentID: "fixture-agent", OperationID: "00000000-0000-4000-8000-000000000001", Enabled: true,
		OwnerPublicKey: "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=",
		Signature:      "fOw9C+rw4HzGV4znLFF7TDD7l28ZnHuCNArerVlWy12I2KZq3M2qz/74FPQej314vFBa0rMLorhT7shVJPc6Dw=="}
	if err := verifyLocalModeCommand(cmd, "fixture-agent"); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*localModeCommand){
		func(c *localModeCommand) { c.Enabled = false },
		func(c *localModeCommand) { c.AgentID = "other" },
		func(c *localModeCommand) { c.ExpectedRevision++ },
		func(c *localModeCommand) { c.OperationID = "bad\noperation" },
		func(c *localModeCommand) { c.Version = 2 },
		func(c *localModeCommand) { c.Signature = "" },
		func(c *localModeCommand) { c.OwnerPublicKey = "bad" },
	} {
		altered := cmd
		mutate(&altered)
		if err := verifyLocalModeCommand(altered, "fixture-agent"); err == nil {
			t.Fatal("accepted modified proof")
		}
	}
}
