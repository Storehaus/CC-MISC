-- Detect the URL used by wget run
local runningProgram = shell.getRunningProgram()  -- e.g. ".temp"
local repoUrl = "https://raw.githubusercontent.com/Storehaus/CC-MISC/master/"

-- Try to infer the URL from the wget command history
-- ComputerCraft puts the URL into the args when using `wget run`
local args = {...}
if args[1] and args[1]:match("^https://raw%.githubusercontent%.com/") then
  repoUrl = args[1]:gsub("installer.lua$", "")
  end
  
  -- Canonical repo
  local canonicalRepo = "https://raw.githubusercontent.com/Storehaus/CC-MISC/master/"
  
  -- Warn if not canonical
  if repoUrl ~= canonicalRepo then
    term.setTextColor(colors.red)
    print("WARNING: Running installer from non-canonical repo!")
    print("Detected repo: " .. repoUrl)
    print("Canonical repo: " .. canonicalRepo)
    print("Press any key to continue...")
    os.pullEvent("key")
    term.setTextColor(colors.white)
    end
    