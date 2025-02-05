# -----------------------------
# Combined Window Manager Code with Drag, Resize, and Close Controls
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
    # Disable QuickEdit mode (0x0040) and ensure extended flags (0x0080) are set.
    $newMode = ($mode -band (-0x41)) -bor 0x0080
    [Win32.ConsoleMode]::SetConsoleMode($handle, $newMode) | Out-Null
}

Disable-QuickEdit

# --- Part 1: Common Utilities & Drawing Routines ---

function Write-ColoredText {
    param (
        [Parameter(Mandatory)]
        [array]$TextParts,   # Each element: @{ Text = "..."; Color = "White"; BackgroundColor = "Black" }
        [int]$X = 0,
        [int]$Y = 0
    )
    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates($X, $Y)
    foreach ($part in $TextParts) {
        Write-Host $part.Text -ForegroundColor $part.Color -BackgroundColor $part.BackgroundColor -NoNewline
    }
    Write-Host ""
}

# Clears a rectangular region rather than the entire console.
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

# Redraw any windows that overlap the affected (union) region.
function Redraw-AffectedRegion {
    param(
         [int]$oldX,
         [int]$oldY,
         [int]$newX,
         [int]$newY,
         [int]$newWidth,
         [int]$newHeight,
         [int]$oldWidth,
         [int]$oldHeight,
         [Object]$dragWindow
    )
    # Compute the right and bottom boundaries for the old and new rectangles.
    $oldRight = $oldX + $oldWidth - 1
    $oldBottom = $oldY + $oldHeight - 1
    $newRight = $newX + $newWidth - 1
    $newBottom = $newY + $newHeight - 1

    # Compute the union of the old and new rectangles.
    $unionLeft   = [Math]::Min($oldX, $newX)
    $unionTop    = [Math]::Min($oldY, $newY)
    $unionRight  = [Math]::Max($oldRight, $newRight)
    $unionBottom = [Math]::Max($oldBottom, $newBottom)
    $unionWidth  = $unionRight - $unionLeft + 1
    $unionHeight = $unionBottom - $unionTop + 1

    # Clear the entire union region.
    Clear-Region -X $unionLeft -Y $unionTop -Width $unionWidth -Height $unionHeight -BackgroundColor "Black"

    # Redraw the taskbar if needed.
    if ($unionTop -lt 3) {
         $global:menuItems = Draw-Taskbar
    }

    # Redraw any windows that may overlap this union.
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
    # Finally, draw the moved or resized window so it appears on top.
    Draw-Window $dragWindow
}

# --- Part 1.1: The Window Box Class (ConsoleBox) ---
# This class draws an ASCII window with a title bar (top border) that includes a red close "X" 
# and a bottom border that displays a resize handle ("R") in yellow.
class ConsoleBox {
    [int]$X
    [int]$Y
    [int]$Width
    [int]$Height
    [string]$BorderColor
    [string]$BackgroundColor
    [string]$Title

    ConsoleBox([int]$x, [int]$y, [int]$width, [int]$height) {
        $this.X = $x
        $this.Y = $y
        $this.Width = $width
        $this.Height = $height
        $this.BorderColor = "White"
        $this.BackgroundColor = "Black"
        $this.Title = ""
    }

    [void] DrawBox() {
        # --- Top Border with Title and Close ("X") Control ---
        if ($this.Width -ge 4) {
            if ([string]::IsNullOrEmpty($this.Title)) {
                # Fallback if no title is set.
                $leftCorner   = "+"
                $leftDashes   = "-" * ($this.Width - 3)
                $closeControl = "X"
                $rightCorner  = "+"
                $topBorderParts = @(
                    @{ Text = $leftCorner; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                    @{ Text = $leftDashes; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                    @{ Text = $closeControl; Color = "Red"; BackgroundColor = $this.BackgroundColor },
                    @{ Text = $rightCorner; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor }
                )
            }
            else {
                # Calculate the available width for the title text.
                $availableWidth = $this.Width - 3
                $titleText = $this.Title

                # If the title is too long, truncate it.
                if ($titleText.Length -gt $availableWidth) {
                    $titleText = $titleText.Substring(0, $availableWidth)
                }
                else {
                    # Otherwise, center the title by padding it with dashes.
                    $padding = $availableWidth - $titleText.Length
                    $leftPadding = [Math]::Floor($padding / 2)
                    $rightPadding = $padding - $leftPadding
                    $titleText = ("-" * $leftPadding) + $titleText + ("-" * $rightPadding)
                }

                $topBorderParts = @(
                    @{ Text = "+"; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                    @{ Text = $titleText; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                    @{ Text = "X"; Color = "Red"; BackgroundColor = $this.BackgroundColor },
                    @{ Text = "+"; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor }
                )
            }
            Write-ColoredText -TextParts $topBorderParts -X $this.X -Y $this.Y
        }
        else {
            $topBorderText = "+" + ("-" * ($this.Width - 2)) + "+"
            Write-ColoredText -TextParts @(@{ Text = $topBorderText; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor }) -X $this.X -Y $this.Y
        }

        # --- Sides ---
        for ($i = 1; $i -lt $this.Height - 1; $i++) {
            $sides = @(
                @{ Text = "|" ; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                @{ Text = (" " * ($this.Width - 2)); Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                @{ Text = "|" ; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor }
            )
            Write-ColoredText -TextParts $sides -X $this.X -Y ($this.Y + $i)
        }

        # --- Bottom Border with Resize Handle (unchanged) ---
        if ($this.Width -ge 4) {
            $leftCorner   = "+"
            $middleWithoutHandle = "-" * ($this.Width - 3)
            $bottomBorderParts = @(
                @{ Text = $leftCorner; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                @{ Text = $middleWithoutHandle; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor },
                @{ Text = "R"; Color = "Yellow"; BackgroundColor = $this.BackgroundColor },
                @{ Text = "+"; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor }
            )
            Write-ColoredText -TextParts $bottomBorderParts -X $this.X -Y ($this.Y + $this.Height - 1)
        }
        else {
            $bottomBorderText = "+" + ("-" * ($this.Width - 2)) + "+"
            Write-ColoredText -TextParts @(@{ Text = $bottomBorderText; Color = $this.BorderColor; BackgroundColor = $this.BackgroundColor }) -X $this.X -Y ($this.Y + $this.Height - 1)
        }
    }

    # WriteContent remains as is.
    [void] WriteContent([array]$textParts, [int]$lineNumber) {
        if ($lineNumber -ge ($this.Height - 2)) { return }
        $adjustedX = $this.X + 1
        Write-ColoredText -TextParts $textParts -X $adjustedX -Y ($this.Y + $lineNumber + 1)
    }
}

# Draw a given window’s border and title.
function Draw-Window($win) {
    $win.Title = "Window ($($win.X),$($win.Y))"
    $win.DrawBox()
    # If you have additional content to draw inside the window, you may call $win.WriteContent here.
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

    # Clear taskbar area.
    for ($row = 0; $row -lt $taskbarHeight; $row++) {
        Write-ColoredText -TextParts @(
            @{
                Text = " " * $consoleWidth;
                Color = "White";
                BackgroundColor = "DarkGray";
            }
        ) -X 0 -Y $row
    }

    # --- Modified Menu Items: Added a New App option ---
    $menuItems = @(
        @{ Text = "New Window"; X = 2;  Action = "NewWindow" },
        @{ Text = "New App";    X = 20; Action = "NewApp" },
        @{ Text = "Exit";       X = 34; Action = "Exit" }
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

# Global list to hold all windows.
$global:windows = @()

function New-Window {
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    $consoleHeight = $Host.UI.RawUI.WindowSize.Height

    # Window dimensions.
    $width = 30
    $height = 10

    # Position the new window randomly within the visible console area (below the taskbar).
    $x = Get-Random -Minimum 0 -Maximum ($consoleWidth - $width)
    $y = Get-Random -Minimum 3 -Maximum ($consoleHeight - $height)

    $win = [ConsoleBox]::new($x, $y, $width, $height)
    $win.BorderColor = "Cyan"
    $win.BackgroundColor = "Black"
    
    # Add the new window to the global list.
    $global:windows += ,$win
    return $win
}

# --- New Function: Creates an App Window ---
function New-AppWindow {
    # Create a new window and customize it as an application.
    $appWin = New-Window
    $appWin.Title = "Simple App"
    Draw-Window $appWin

    # Define the app's content.
    $appContent = @(
        @{ Text = "Welcome to my simple app!"; Color = "Green"; BackgroundColor = $appWin.BackgroundColor },
        @{ Text = "This is a demo application."; Color = "Green"; BackgroundColor = $appWin.BackgroundColor }
    )
    $appWin.WriteContent($appContent, 0)
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
# Now supporting dragging (from the top title bar), clicking the red "X" to close,
# and resizing (by dragging the bottom-right resize handle).
function Start-WindowManager {
    $menuItems = Draw-Taskbar
    Draw-AllWindows

    # Hide cursor while running.
    [Console]::CursorVisible = $false

    # Variables that support dragging and resizing.
    $dragWindow  = $null
    $resizeWindow = $null
    $dragOffset  = @{ X = 0; Y = 0 }
    # Variables for resizing.
    $startResizeX = 0
    $startResizeY = 0
    $resizeInitialWidth = 0
    $resizeInitialHeight = 0

    try {
        while ($true) {
            if ([System.Windows.Forms.Control]::MouseButtons -eq "Left") {
                $pos = Get-ConsoleCellPosition

                # If click is on the taskbar row.
                if ($pos.Y -eq 1) {
                    foreach ($item in $menuItems) {
                        if ($pos.X -ge $item.X -and $pos.X -lt ($item.X + $item.Text.Length)) {
                            switch ($item.Action) {
                                "NewWindow" {
                                    $newWin = New-Window
                                    Draw-Window $newWin
                                    Start-Sleep -Milliseconds 200
                                }
                                "NewApp" {
                                    New-AppWindow
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
                    # If we are not already dragging or resizing, check for a new action.
                    if (-not $dragWindow -and -not $resizeWindow) {
                        # FIRST: Check for a resize request (click within the bottom-right 2x2 area).
                        foreach ($win in $global:windows) {
                            $resizeAreaWidth = 2
                            $resizeAreaHeight = 2
                            $resizeXStart = $win.X + $win.Width - $resizeAreaWidth
                            $resizeYStart = $win.Y + $win.Height - $resizeAreaHeight
                            if (($pos.X -ge $resizeXStart) -and ($pos.X -lt ($win.X + $win.Width)) -and
                                ($pos.Y -ge $resizeYStart) -and ($pos.Y -lt ($win.Y + $win.Height))) {
                                    $resizeWindow = $win
                                    $startResizeX = $pos.X
                                    $startResizeY = $pos.Y
                                    $resizeInitialWidth = $win.Width
                                    $resizeInitialHeight = $win.Height
                                    break
                            }
                        }
                        # SECOND: If not resizing, check for a click in the window’s top border.
                        if (-not $resizeWindow) {
                            foreach ($win in $global:windows) {
                                if ($pos.Y -eq $win.Y) {
                                    # Check if click is on the close ("X") control.
                                    if ($pos.X -eq ($win.X + $win.Width - 2)) {
                                        Clear-Region -X $win.X -Y $win.Y -Width $win.Width -Height $win.Height -BackgroundColor "Black"
                                        $global:windows = $global:windows | Where-Object { $_ -ne $win }
                                        Draw-AllWindows
                                        break
                                    }
                                    # Otherwise, if within the title bar area (excluding borders), start dragging.
                                    elseif (($pos.X -ge $win.X + 1) -and ($pos.X -lt ($win.X + $win.Width - 1))) {
                                        $dragWindow = $win
                                        $dragOffset.X = $pos.X - $win.X
                                        $dragOffset.Y = $pos.Y - $win.Y
                                        break
                                    }
                                }
                            }
                        }
                    }
                    # If already in resizing mode, update window size.
                    if ($resizeWindow) {
						$deltaX = $pos.X - $startResizeX
						$deltaY = $pos.Y - $startResizeY
						$newWidth = $resizeInitialWidth + $deltaX
						$newHeight = $resizeInitialHeight + $deltaY
						if ($newWidth -lt 10) { $newWidth = 10 }
						if ($newHeight -lt 5) { $newHeight = 5 }
						
						# Capture current (old) values before updating.
						$oldX = $resizeWindow.X
						$oldY = $resizeWindow.Y
						$oldWidth = $resizeWindow.Width
						$oldHeight = $resizeWindow.Height
						
						# Update to the new size.
						$resizeWindow.Width = $newWidth
						$resizeWindow.Height = $newHeight
						
						# Clear and redraw using both the old and new dimensions.
						Redraw-AffectedRegion -oldX $oldX -oldY $oldY -newX $resizeWindow.X -newY $resizeWindow.Y `
							-newWidth $resizeWindow.Width -newHeight $resizeWindow.Height -oldWidth $oldWidth -oldHeight $oldHeight `
							-dragWindow $resizeWindow
					}
                    # If in dragging mode, update window position.
                    elseif ($dragWindow) {
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

						# For dragging, the size is unchanging.
						$oldX = $dragWindow.X
						$oldY = $dragWindow.Y
						$oldWidth = $dragWindow.Width
						$oldHeight = $dragWindow.Height

						$dragWindow.X = $newX
						$dragWindow.Y = $newY
						
						Redraw-AffectedRegion -oldX $oldX -oldY $oldY -newX $newX -newY $newY `
							-newWidth $dragWindow.Width -newHeight $dragWindow.Height -oldWidth $oldWidth -oldHeight $oldHeight `
							-dragWindow $dragWindow
					}
                }
            }
            else {
                # Mouse button released; reset both dragging and resizing.
                $dragWindow = $null
                $resizeWindow = $null
            }
            Start-Sleep -Milliseconds 30
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

# -----------------------------
# Start the Window Manager
# -----------------------------
Clear-Host
Start-WindowManager
