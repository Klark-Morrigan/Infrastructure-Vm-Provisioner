<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 alongside the other up/seed/* helpers.
#>

# ---------------------------------------------------------------------------
# Format-CloudInitLiteralBlock
#   Indents each line of the body by six spaces so it can be embedded as a
#   YAML literal block scalar under a cloud-config write_files entry:
#
#       write_files:
#         - path: /etc/foo
#           content: |
#             <body line 1>
#             <body line 2>
#
#   The six spaces = two for the list item ("  - ") + four for the
#   content key ("    content: |"). Shared by every cloud-init seed that
#   embeds an arbitrary file body.
# ---------------------------------------------------------------------------
function Format-CloudInitLiteralBlock {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Body
    )

    return ($Body -split "`r?`n" |
        ForEach-Object { "      $_" }) -join "`n"
}
