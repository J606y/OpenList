package drivers

import (
	// Slimmed for self-use: only OneDrive (App + standard) and PikPak are kept.
	_ "github.com/OpenListTeam/OpenList/v4/drivers/onedrive"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/onedrive_app"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/pikpak"
)

// All do nothing,just for import
// same as _ import
func All() {
}
