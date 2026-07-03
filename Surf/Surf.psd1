@{
    RootModule           = 'Surf.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'ffbb58b2-9820-4242-85ec-50fb26b0fc9f'
    Author               = 'Rob Scholey'
    Copyright            = '(c) 2026 Rob Scholey. All rights reserved.'
    Description          = 'An interactive directory navigator for the terminal. Browse with arrow keys, cd with Enter, plus favourites, a blacklist, recursive folder search, and Windows Terminal tab integration. Windows only.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('surf')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('TUI', 'navigation', 'filesystem', 'directory', 'interactive', 'Windows')
            LicenseUri   = 'https://github.com/RobertScholey98/surf/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/RobertScholey98/surf'
            ReleaseNotes = 'Initial public release.'
        }
    }
}
