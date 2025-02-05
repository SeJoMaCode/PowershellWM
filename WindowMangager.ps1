# -----------------------------
# Combined Window Manager Code with a Red “X” Close Button
# -----------------------------

# --- Part 0: Disable QuickEdit Mode ---
function Disable-QuickEdit {
    Add-Type -MemberDefinition @"
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
"@ -Name ConsoleMode -Namespace Win32 -PassThru | Out-Null

    $STD_INPUT_HANDLE = -10
    $handle = [Win32.ConsoleMode]::GetStdHandle($STD_INPUT_HANDLE)
    $mode = 0
    [Win32.ConsoleMode]::GetConsoleMode($handle, [ref]$mode) | Out-Null
    $newMode = ($mode -band (-0x41)) -bor 0x0080
    [Win32.ConsoleMode]::SetConsoleMode($handle, $newMode) | Out-Null
}

Disable-QuickEdit

# --- Part 1: Common Utilities & Drawing Routines ---

function Write-ColoredText {
    param (
        [Parameter(Mandatory)]
        [array]$TextParts,   # Array of hash tables with Text, Color, and BackgroundColor
        [int]$X = 0,
        [int]$Y = 0
    )
    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates($X, $Y)
    foreach ($part in $TextParts) {
        Write-Host $part.Text -ForegroundColor $part.Color -BackgroundColor $part.BackgroundColor -NoNewline
    }
    Write-Host ""
}

function Clear-Region {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$BackgroundColor = "Black",
        [string]$ForegroundColor = "White"
    )
    for ($row = $Y; $row -lt ($Y + $Height); $row++) {
        Write-ColoredText -TextParts @(
            @{
                Text = " " * $Width;
                Color = $ForegroundColor;
                BackgroundColor = $BackgroundColor
            }
        ) -X $X -Y $row
    }
}

function Redraw-AffectedRegion {
    param(
         [int]$oldX,
         [int]$oldY,
         [int]$newX,
         [int]$newY,
         [int]$Width,
         [int]$Height,
         [Object]$dragWindow
    )
    $unionLeft   = [Math]::Min($oldX, $newX)
    $unionTop    = [Math]::Min($oldY, $newY)
    $unionRight  = [Math]::Max($oldX + $Width - 1, $newX + $Width - 1)
    $unionBottom = [Math]::Max($oldY + $Height - 1, $newY + $Height - 1)
    $unionWidth  = $unionRight - $unionLeft + 1
    $unionHeight = $unionBottom - $unionTop + 1

    Clear-Region -X $unionLeft -Y $unionTop -Width $unionWidth -Height $unionHeight -BackgroundColor "Black"

    if ($unionTop -lt 3) {
         $global:menuItems = Draw-Taskbar
    }

    foreach ($win in $global:windows) {
         $winLeft   = $win.X
         $winTop    = $win.Y
         $winRight  = $win.X + $win.Width - 1
         $winBottom = $win.Y + $win.Height - 1
         if (!($winRight -lt $unionLeft -or $winLeft -gt $unionRight -or $winBottom -lt $unionTop -or $winTop -gt $unionBottom)) {
              if ($win -ne $dragWindow) {
                  Draw-Window $win
              }
         }
    }
    Draw-Window $dragWindow
}

# --- Part 1.1: The Window Box Class ---
# This version of ConsoleBox draws the top border with a close button ("X")
# in red.
class ConsoleBox {
    [int]$X
    [int]$Y
    [int]$Width
    [int]$Height
    [string]$BorderColor
    [string]$BackgroundColor

    ConsoleBox([int]$x, [int]$y, [int]$width, [int]$height) {
        $this.X = $x
        $this.Y = $y
        $this.Width = $width
        $this.Height = $height
        $this.BorderColor = "White"
        $this.BackgroundColor = "Black"
    }

    [void] DrawBox() {
        if ($this.Width -ge 4) {
            # Build the top border out of segments:
            #  - Left corner ("+")
            #  - A series of dashes
            #  - The close control "X" in red
            #  - The right corner ("+")
            $leftCorner   = "+"
            $leftDashes   = "-" * ($this.Width - 3)
            $closeControl = "X"
            $rightCorner  = "+"
            $topBorderParts = @(
                @{ Text = $leftCorner;   Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                @{ Text = $leftDashes;   Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                @{ Text = $closeControl; Color = "Red";           BackgroundColor = $this.BackgroundColor },
                @{ Text = $rightCorner;  Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor }
            )
            Write-ColoredText -TextParts $topBorderParts -X $this.X -Y $this.Y
        }
        else {
            $topBorderText = "+" + ("-" * ($this.Width - 2)) + "+"
            $topBorder = @{
                Text = $topBorderText;
                Color = $this.BorderColor;
                BackgroundColor = $this.BackgroundColor
            }
            Write-ColoredText -TextParts @($topBorder) -X $this.X -Y $this.Y
        }

        for ($i = 1; $i -lt $this.Height - 1; $i++) {
            $sides = @(
                @{ Text = "|" ; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                @{ Text = (" " * ($this.Width - 2)); Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                @{ Text = "|" ; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor }
            )
            Write-ColoredText -TextParts $sides -X $this.X -Y ($this.Y + $i)
        }

        $bottomBorder = @{
            Text = "+" + ("-" * ($this.Width - 2)) + "+"
            Color = $this.BorderColor
            BackgroundColor = $this.BackgroundColor
        }
        Write-ColoredText -TextParts @($bottomBorder) -X $this.X -Y ($this.Y + $this.Height - 1)
    }

    [void] WriteContent([array]$textParts, [int]$lineNumber) {
        if ($lineNumber -ge ($this.Height - 2)) { return }
        $adjustedX = $this.X + 1
        Write-ColoredText -TextParts $textParts -X $adjustedX -Y ($this.Y + $lineNumber + 1)
    }
}

# Draw a given window’s border and title.
function Draw-Window($win) {
    $win.DrawBox()
    $title = "Window ($($win.X),$($win.Y))"
    $win.WriteContent(@(
        @{ Text = $title; Color = "White"; BackgroundColor = "DarkBlue" }
    ), 0)
}

# --- Part 2: Mouse and Console Coordinate Conversion ---

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ConsoleHelper {
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);
    public struct POINT {
        public int X;
        public int Y;
    }
}
"@

function Get-ConsoleCellPosition {
    $point = New-Object ConsoleHelper+POINT
    [ConsoleHelper]::GetCursorPos([ref]$point) | Out-Null
    $windowHandle = [ConsoleHelper]::GetConsoleWindow()
    [ConsoleHelper]::ScreenToClient($windowHandle, [ref]$point) | Out-Null
    $charWidth = 8
    $charHeight = 16
    $cellX = [Math]::Floor($point.X / $charWidth)
    $cellY = [Math]::Floor($point.Y / $charHeight)
    return @{ X = [Math]::Max(0, $cellX); Y = [Math]::Max(0, $cellY) }
}

# --- Part 3: Desktop and Taskbar Functions ---

function Draw-Taskbar {
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    $taskbarHeight = 3

    for ($row = 0; $row -lt $taskbarHeight; $row++) {
        Write-ColoredText -TextParts @(
            @{
                Text = " " * $consoleWidth;
                Color = "White";
                BackgroundColor = "DarkGray";
            }
        ) -X 0 -Y $row
    }

    $menuItems = @(
        @{ Text = "New Window"; X = 2; Action = "NewWindow" },
        @{ Text = "Exit";       X = 20; Action = "Exit" }
    )

    foreach ($item in $menuItems) {
        Write-ColoredText -TextParts @(
            @{
                Text = $item.Text;
                Color = "Black";
                BackgroundColor = "Gray";
            }
        ) -X $item.X -Y 1
    }

    return $menuItems
}

$global:windows = @()

function New-Window {
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    $consoleHeight = $Host.UI.RawUI.WindowSize.Height

    $width = 30
    $height = 10

    $x = Get-Random -Minimum 0 -Maximum ($consoleWidth - $width)
    $y = Get-Random -Minimum 3 -Maximum ($consoleHeight - $height)

    $win = [ConsoleBox]::new($x, $y, $width, $height)
    $win.BorderColor = "Cyan"
    $win.BackgroundColor = "Black"

    $global:windows += ,$win
    return $win
}

function Draw-AllWindows {
    foreach ($win in $global:windows) {
        Draw-Window $win
    }
}

function Clear-Desktop {
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    $consoleHeight = $Host.UI.RawUI.WindowSize.Height
    $taskbarHeight = 3

    for ($row = $taskbarHeight; $row -lt $consoleHeight; $row++) {
        Write-ColoredText -TextParts @(
            @{
                Text = " " * $consoleWidth;
                Color = "White";
                BackgroundColor = "Black";
            }
        ) -X 0 -Y $row
    }
}

# --- Part 4: Main Window Manager Loop ---

function Start-WindowManager {
    $menuItems = Draw-Taskbar
    Draw-AllWindows

    [Console]::CursorVisible = $false

    $dragWindow  = $null
    $dragOffset  = @{ X = 0; Y = 0 }

    try {
        while ($true) {
            if ([System.Windows.Forms.Control]::MouseButtons -eq "Left") {
                $pos = Get-ConsoleCellPosition

                # Check if the click is on the taskbar (row 1)
                if ($pos.Y -eq 1) {
                    foreach ($item in $menuItems) {
                        if ($pos.X -ge $item.X -and $pos.X -lt ($item.X + $item.Text.Length)) {
                            switch ($item.Action) {
                                "NewWindow" {
                                    $newWin = New-Window
                                    Draw-Window $newWin
                                    Start-Sleep -Milliseconds 200
                                }
                                "Exit" {
                                    Clear-Host
                                    return
                                }
                            }
                        }
                    }
                }
                else {
                    # Check for click on the window's title bar.
                    # First, check if it's on the close ("X") control.
                    $windowClosed = $false
                    if (-not $dragWindow) {
                        foreach ($win in $global:windows) {
                            if ($pos.Y -eq $win.Y) {
                                if ($pos.X -eq ($win.X + $win.Width - 2)) {
                                    Clear-Region -X $win.X -Y $win.Y -Width $win.Width -Height $win.Height -BackgroundColor "Black"
                                    $global:windows = $global:windows | Where-Object { $_ -ne $win }
                                    Draw-AllWindows
                                    $windowClosed = $true
                                    break
                                }
                                elseif (($pos.X -ge $win.X + 1) -and ($pos.X -lt ($win.X + $win.Width - 1))) {
                                    $dragWindow = $win
                                    $dragOffset.X = $pos.X - $win.X
                                    $dragOffset.Y = $pos.Y - $win.Y
                                    break
                                }
                            }
                        }
                        if ($windowClosed) { continue }
                    }
                    else {
                        $newX = $pos.X - $dragOffset.X
                        $newY = $pos.Y - $dragOffset.Y

                        $consoleWidth = $Host.UI.RawUI.WindowSize.Width
                        $consoleHeight = $Host.UI.RawUI.WindowSize.Height
                        if ($newX -lt 0) { $newX = 0 }
                        if ($newY -lt 3) { $newY = 3 }
                        if ($newX + $dragWindow.Width - 1 -gt $consoleWidth) {
                            $newX = $consoleWidth - $dragWindow.Width
                        }
                        if ($newY + $dragWindow.Height + 1 -gt $consoleHeight) {
                            $newY = $consoleHeight - $dragWindow.Height - 1
                        }

                        $oldX = $dragWindow.X
                        $oldY = $dragWindow.Y
                        $dragWindow.X = $newX
                        $dragWindow.Y = $newY
                        Redraw-AffectedRegion -oldX $oldX -oldY $oldY -newX $newX -newY $newY -Width $dragWindow.Width -Height $dragWindow.Height -dragWindow $dragWindow
                    }
                }
            }
            else {
                $dragWindow = $null
            }

            Start-Sleep -Milliseconds 30
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

Clear-Host
Start-WindowManager