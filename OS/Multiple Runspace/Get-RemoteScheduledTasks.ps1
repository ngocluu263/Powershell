Function Get-RemoteScheduledTasks
{
    <#
    .SYNOPSIS
        Gather scheduled task information from a remote system or systems.
    .DESCRIPTION
        Gather scheduled task information from a remote system or systems. If remote credentials
        are provided PSremoting will be utilized.
    .PARAMETER ComputerName
        Specifies the target computer or computers for data query.
    .PARAMETER UseRemoting
        Override defaults and use PSRemoting. If an alternate credential is specified PSRemoting is assumed.
    .PARAMETER ThrottleLimit
        Specifies the maximum number of systems to inventory simultaneously 
    .PARAMETER Timeout
        Specifies the maximum time in second command can run in background before terminating this thread.
    .PARAMETER ShowProgress
        Show progress bar information
    .EXAMPLE
        PS > (Get-RemoteScheduledTasks).Tasks | 
             Where {(!$_.Hidden) -and ($_.Enabled) -and ($_.NextRunTime -ne 'None')} | 
             Select Name,Enabled,NextRunTime,Author

        Name                     Enabled   NextRunTime               Author                       
        ----                     -------   -----------               ------                   
        Adobe Flash Player Upd...True      10/4/2013 10:24:00 PM     Adobe
       
        Description
        -----------
        Gathers all scheduled tasks then filters out all which are enabled, has a next
        run time, and is not hidden and displays the result in a table.
    .EXAMPLE
        PS > $cred = Get-Credential
        PS > $Servers = @('SERVER1','SERVER2')
        PS > $a = Get-RemoteScheduledTasks -Credential $cred -ComputerName $Servers

        Description
        -----------
        Using an alternate credential (and thus PSremoting), $a gets assigned all of the 
        scheduled tasks from SERVER1 and SERVER2.
        
    .NOTES
        Author: Zachary Loeber
        Site: http://www.the-little-things.net/
        Requires: Powershell 2.0

        Version History
        1.0.0 - 10/04/2013
        - Initial release
        
        Note: 
        
        I used code from a few sources to create this script;
            - http://p0w3rsh3ll.wordpress.com/2012/10/22/working-with-scheduled-tasks/
            - http://gallery.technet.microsoft.com/Get-Scheduled-tasks-from-3a377294
        
        I was unable to find several of the Task last exit codes. A good number of them
        from the following source have been included tough;
            - http://msdn.microsoft.com/en-us/library/windows/desktop/aa383604(v=vs.85).aspx
    #>
    [cmdletbinding()]
    PARAM
    (
        [Parameter(HelpMessage="Computer or computers to gather information from",
                   ValueFromPipeline=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=0)]
        [ValidateNotNullOrEmpty()]
        [Alias('DNSHostName','PSComputerName')]
        [string[]]
        $ComputerName=$env:computername,

        [Parameter(HelpMessage="Override defaults and use PSRemoting. If an alternate credential is specified PSRemoting is assumed.")]
        [switch]
        $UseRemoting,
        
        [Parameter(HelpMessage="Maximum number of concurrent threads")]
        [ValidateRange(1,65535)]
        [int32]
        $ThrottleLimit = 32,

        [Parameter(HelpMessage="Timeout before a thread stops trying to gather the information")]
        [ValidateRange(1,65535)]
        [int32]
        $Timeout = 120,

        [Parameter(HelpMessage="Display progress of function")]
        [switch]
        $ShowProgress,
        
        [Parameter(HelpMessage="Set this if you want the function to prompt for alternate credentials")]
        [switch]
        $PromptForCredential,
        
        [Parameter(HelpMessage="Set this if you want to provide your own alternate credentials")]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )
    BEGIN
    {
        $ProcessWithPSRemoting = $UseRemoting
        $ComputerNames = @()
        
        # Gather possible local host names and IPs to prevent credential utilization in some cases
        Write-Verbose -Message 'Scheduled Tasks: Creating local hostname list'
        
        $IPAddresses = [net.dns]::GetHostAddresses($env:COMPUTERNAME) | Select-Object -ExpandProperty IpAddressToString
        $HostNames = $IPAddresses | ForEach-Object {
            try {
                [net.dns]::GetHostByAddress($_)
            } catch {
                # We do not care about errors here...
            }
        } | Select-Object -ExpandProperty HostName -Unique
        $LocalHost = @('', '.', 'localhost', $env:COMPUTERNAME, '::1', '127.0.0.1') + $IPAddresses + $HostNames
 
        Write-Verbose -Message 'Scheduled Tasks: Creating initial variables'
        $runspacetimers       = [HashTable]::Synchronized(@{})
        $runspaces            = New-Object -TypeName System.Collections.ArrayList
        $bgRunspaceCounter    = 0
        
        if ($PromptForCredential)
        {
            $Credential = Get-Credential
            $ProcessWithPSRemoting = $true
        }
        
        Write-Verbose -Message 'Scheduled Tasks: Creating Initial Session State'
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($ExternalVariable in ('runspacetimers', 'Credential', 'LocalHost'))
        {
            Write-Verbose -Message "Scheduled Tasks: Adding variable $ExternalVariable to initial session state"
            $iss.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $ExternalVariable, (Get-Variable -Name $ExternalVariable -ValueOnly), ''))
        }
        
        Write-Verbose -Message 'Scheduled Tasks: Creating runspace pool'
        $rp = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit, $iss, $Host)
        $rp.ApartmentState = 'STA'
        $rp.Open()
 
        # This is the actual code called for each computer
        Write-Verbose -Message 'Scheduled Tasks: Defining background runspaces scriptblock'
        $ScriptBlock = 
        {
            Param
            (
                [Parameter(Position=0)]
                [string]
                $ComputerName,
 
                [Parameter(Position=1)]
                [int]
                $bgRunspaceID,
                
                [Parameter()]
                [switch]
                $UseRemoting
            )

            $runspacetimers.$bgRunspaceID = Get-Date
            $GetScheduledTask = {
                param(
                	$computername = "localhost"
                )

                Function Get-TaskSubFolders
                {
                    param(                    	
                        [string]$folder = '\',
                        [switch]$recurse
                    )
                    $folder
                    if ($recurse)
                    {
                        $TaskService.GetFolder($folder).GetFolders(0) | 
                        ForEach-Object {
                            Get-TaskSubFolders $_.Path -Recurse
                        }
                    } 
                    else 
                    {
                        $TaskService.GetFolder($folder).GetFolders(0)
                    }
                }

                try 
                {
                	$TaskService = new-object -com("Schedule.Service") 
                    $TaskService.connect($ComputerName) 
                    $AllFolders = Get-TaskSubFolders -Recurse
                    $TaskResults = @()

                    foreach ($Folder in $AllFolders) 
                    {
                        $TaskService.GetFolder($Folder).GetTasks(1) | 
                        Foreach-Object {
                            switch ([int]$_.State)
                            {
                                0 { $State = 'Unknown'}
                                1 { $State = 'Disabled'}
                                2 { $State = 'Queued'}
                                3 { $State = 'Ready'}
                                4 { $State = 'Running'}
                                default {$State = $_ }
                            }
                            
                            switch ($_.NextRunTime) 
                            {
                                (Get-Date -Year 1899 -Month 12 -Day 30 -Minute 00 -Hour 00 -Second 00) {$NextRunTime = "None"}
                                default {$NextRunTime = $_}
                            }
                             
                            switch ($_.LastRunTime) 
                            {
                                (Get-Date -Year 1899 -Month 12 -Day 30 -Minute 00 -Hour 00 -Second 00) {$LastRunTime = "Never"}
                                default {$LastRunTime = $_}
                            } 

                            switch (([xml]$_.XML).Task.RegistrationInfo.Author)
                            {
                                '$(@%ProgramFiles%\Windows Media Player\wmpnscfg.exe,-1001)'   { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\acproxy.dll,-101)'                   { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\aepdu.dll,-701)'                     { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\aitagent.exe,-701)'                  { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\appidsvc.dll,-201)'                  { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\appidsvc.dll,-301)'                  { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\System32\AuxiliaryDisplayServices.dll,-1001)' { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\bfe.dll,-2001)'                      { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\BthUdTask.exe,-1002)'                { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\cscui.dll,-5001)'                    { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\System32\DFDTS.dll,-101)'                     { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\dimsjob.dll,-101)'                   { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\dps.dll,-600)'                       { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\drivers\tcpip.sys,-10000)'           { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\defragsvc.dll,-801)'                 { $Author = 'Microsoft Corporation'}
                                '$(@%systemRoot%\system32\energy.dll,-103)'                    { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\HotStartUserAgent.dll,-502)'         { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\kernelceip.dll,-600)'                { $Author = 'Microsoft Corporation'}
                                '$(@%systemRoot%\System32\lpremove.exe,-100)'                  { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\memdiag.dll,-230)'                   { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\mscms.dll,-201)'                     { $Author = 'Microsoft Corporation'}
                                '$(@%systemRoot%\System32\msdrm.dll,-6001)'                    { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\msra.exe,-686)'                      { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\nettrace.dll,-6911)'                 { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\osppc.dll,-200)'                     { $Author = 'Microsoft Corporation'}
                                '$(@%systemRoot%\System32\perftrack.dll,-2003)'                { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\PortableDeviceApi.dll,-102)'         { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\profsvc,-500)'                       { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\RacEngn.dll,-501)'                   { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\rasmbmgr.dll,-201)'                  { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\regidle.dll,-600)'                   { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\sdclt.exe,-2193)'                    { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\sdiagschd.dll,-101)'                 { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\sppc.dll,-200)'                      { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\srrstr.dll,-321)'                    { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\upnphost.dll,-215)'                  { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\usbceip.dll,-600)'                   { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\w32time.dll,-202)'                   { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\wdc.dll,-10041)'                     { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\wer.dll,-293)'                       { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\System32\wpcmig.dll,-301)'                    { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\System32\wpcumi.dll,-301)'                    { $Author = 'Microsoft Corporation'}
                                '$(@%systemroot%\system32\winsatapi.dll,-112)'                 { $Author = 'Microsoft Corporation'}
                                '$(@%SystemRoot%\system32\wat\WatUX.exe,-702)'                 { $Author = 'Microsoft Corporation'}
                                default {$Author = $_ }                                   
                            }
                            switch (([xml]$_.XML).Task.RegistrationInfo.Date)
                            {
                                ''      {$Created = 'Unknown'}
                                default {$Created =  Get-Date -Date $_ }                                
                            }
                            Switch (([xml]$_.XML).Task.Settings.Hidden)
                            {
                                false { $Hidden = $false}
                                true  { $Hidden = $true }
                                default { $Hidden = $false}
                            }
                            Switch (([xml]$_.xml).Task.Principals.Principal.UserID)
                            {
                                'S-1-5-18' {$userid = 'Local System'}
                                'S-1-5-19' {$userid = 'Local Service'}
                                'S-1-5-20' {$userid = 'Network Service'}
                                default    {$userid = $_ }
                            }
                            Switch ($_.lasttaskresult)
                            {
                                '0' { $LastTaskDetails = 'The operation completed successfully.' }
                                '1' { $LastTaskDetails = 'Incorrect function called or unknown function called.' }
                                '2' { $LastTaskDetails = 'File not found.' }
                                '10' { $LastTaskDetails = 'The environment is incorrect.' }
                                '267008' { $LastTaskDetails = 'Task is ready to run at its next scheduled time.' }
                                '267009' { $LastTaskDetails = 'Task is currently running.' }
                                '267010' { $LastTaskDetails = 'The task will not run at the scheduled times because it has been disabled.' }
                                '267011' { $LastTaskDetails = 'Task has not yet run.' }
                                '267012' { $LastTaskDetails = 'There are no more runs scheduled for this task.' }
                                '267013' { $LastTaskDetails = 'One or more of the properties that are needed to run this task on a schedule have not been set.' }
                                '267014' { $LastTaskDetails = 'The last run of the task was terminated by the user.' }
                                '267015' { $LastTaskDetails = 'Either the task has no triggers or the existing triggers are disabled or not set.' }
                                '2147750671' { $LastTaskDetails = 'Credentials became corrupted.' }
                                '2147750687' { $LastTaskDetails = 'An instance of this task is already running.' }
                                '2147943645' { $LastTaskDetails = 'The service is not available (is "Run only when an user is logged on" checked?).' }
                                '3221225786' { $LastTaskDetails = 'The application terminated as a result of a CTRL+C.' }
                                '3228369022' { $LastTaskDetails = 'Unknown software exception.' }
                                default    {$LastTaskDetails = $_ }
                            }
                            $TaskProps = @{
                                'Name' = $_.name
                                'Path' = $_.path
                                'State' = $State
                                'Created' = $Created
                                'Enabled' = $_.enabled
                                'Hidden' = $Hidden
                                'LastRunTime' = $LastRunTime
                                'LastTaskResult' = $_.lasttaskresult
                                'LastTaskDetails' = $LastTaskDetails
                                'NumberOfMissedRuns' = $_.numberofmissedruns
                                'NextRunTime' = $NextRunTime
                                'Author' =  $Author
                                'UserId' = $UserID
                                'Description' = ([xml]$_.xml).Task.RegistrationInfo.Description
                            }
                	        $TaskResults += New-Object PSCustomObject -Property $TaskProps
                        }
                    }
                    Write-Output -InputObject $TaskResults
                }
                catch
                {
                    Write-Warning -Message ('Scheduled Tasks: {0}: {1}' -f $ComputerName, $_.Exception.Message)
                }
            }

            try 
            {
                Write-Verbose -Message ('Scheduled Tasks: Runspace {0}: Start' -f $ComputerName)
                $RemoteSplat = @{
                    ComputerName = $ComputerName
                    ErrorAction = 'Stop'
                }
                $ProcessWithPSRemoting = $UseRemoting
                if (($LocalHost -notcontains $ComputerName) -and 
                    ($Credential -ne [System.Management.Automation.PSCredential]::Empty))
                {
                    $RemoteSplat.Credential = $Credential
                    $ProcessWithPSRemoting = $true
                }

                Write-Verbose -Message ('Scheduled Tasks: Runspace {0}: information' -f $ComputerName)
                $PSDateTime = Get-Date
                $defaultProperties    = @('ComputerName','Tasks')

            	if ($ProcessWithPSRemoting)
                {
                    Write-Verbose -Message ('Scheduled Tasks: Using PSremoting on {0}' -f $ComputerName)
                    $Results = @(Invoke-Command  @RemoteSplat `
                                                 -ScriptBlock  $GetScheduledTask `
                                                 -ArgumentList 'localhost')
                    $PSConnection = 'PSRemoting'
                }
                else
                {
                    Write-Verbose -Message ('Scheduled Tasks: Directly connecting to {0}' -f $ComputerName)
                    $Results = @(&$GetScheduledTask -ComputerName $ComputerName)
                    $PSConnection = 'Direct'
                }
                
                $ResultProperty = @{
                    'PSComputerName'= $ComputerName
                    'PSDateTime'    = $PSDateTime
                    'PSConnection'  = $PSConnection
                    'ComputerName'  = $ComputerName
                    'Tasks'         = $Results                    
                }
                $ResultObject = New-Object -TypeName PSObject -Property $ResultProperty
                
                # Setup the default properties for output
                $ResultObject.PSObject.TypeNames.Insert(0,'My.ScheduledTask.Info')
                $defaultDisplayPropertySet = New-Object System.Management.Automation.PSPropertySet('DefaultDisplayPropertySet',[string[]]$defaultProperties)
                $PSStandardMembers = [System.Management.Automation.PSMemberInfo[]]@($defaultDisplayPropertySet)
                $ResultObject | Add-Member MemberSet PSStandardMembers $PSStandardMembers

                Write-Output -InputObject $ResultObject
            }            
            catch
            {
                Write-Warning -Message ('Scheduled Tasks: {0}: {1}' -f $ComputerName, $_.Exception.Message)
            }
            Write-Verbose -Message ('Scheduled Tasks: Runspace {0}: End' -f $ComputerName)
        }
        
        Function Get-Result
        {
            [CmdletBinding()]
            Param 
            (
                [switch]$Wait
            )
            do
            {
                $More = $false
                foreach ($runspace in $runspaces)
                {
                    $StartTime = $runspacetimers.($runspace.ID)
                    if ($runspace.Handle.isCompleted)
                    {
                        Write-Verbose -Message ('Scheduled Tasks: Thread done for {0}' -f $runspace.IObject)
                        $runspace.PowerShell.EndInvoke($runspace.Handle)
                        $runspace.PowerShell.Dispose()
                        $runspace.PowerShell = $null
                        $runspace.Handle = $null
                    }
                    elseif ($runspace.Handle -ne $null)
                    {
                        $More = $true
                    }
                    if ($Timeout -and $StartTime)
                    {
                        if ((New-TimeSpan -Start $StartTime).TotalSeconds -ge $Timeout -and $runspace.PowerShell)
                        {
                            Write-Warning -Message ('Timeout {0}' -f $runspace.IObject)
                            $runspace.PowerShell.Dispose()
                            $runspace.PowerShell = $null
                            $runspace.Handle = $null
                        }
                    }
                }
                if ($More -and $PSBoundParameters['Wait'])
                {
                    Start-Sleep -Milliseconds 100
                }
                foreach ($threat in $runspaces.Clone())
                {
                    if ( -not $threat.handle)
                    {
                        Write-Verbose -Message ('Scheduled Tasks: Removing {0} from runspaces' -f $threat.IObject)
                        $runspaces.Remove($threat)
                    }
                }
                if ($ShowProgress)
                {
                    $ProgressSplatting = @{
                        Activity = 'Scheduled Tasks: Getting info'
                        Status = 'Scheduled Tasks: {0} of {1} total threads done' -f ($bgRunspaceCounter - $runspaces.Count), $bgRunspaceCounter
                        PercentComplete = ($bgRunspaceCounter - $runspaces.Count) / $bgRunspaceCounter * 100
                    }
                    Write-Progress @ProgressSplatting
                }
            }
            while ($More -and $PSBoundParameters['Wait'])
        }
    }
    PROCESS
    {
        $ComputerNames += $ComputerName
    }
    END
    {
        foreach ($Computer in $ComputerName)
        {
            $bgRunspaceCounter++
            $psCMD = [System.Management.Automation.PowerShell]::Create().AddScript($ScriptBlock)
            $null = $psCMD.AddParameter('bgRunspaceID',$bgRunspaceCounter)
            $null = $psCMD.AddParameter('ComputerName',$Computer)
            $null = $psCMD.AddParameter('UseRemoting',$UseRemoting)
            $null = $psCMD.AddParameter('Verbose',$VerbosePreference)
            $psCMD.RunspacePool = $rp
 
            Write-Verbose -Message ('Scheduled Tasks: Starting {0}' -f $Computer)
            [void]$runspaces.Add(@{
                Handle = $psCMD.BeginInvoke()
                PowerShell = $psCMD
                IObject = $Computer
                ID = $bgRunspaceCounter
            })
           Get-Result
        }
        
        Get-Result -Wait
        if ($ShowProgress)
        {
            Write-Progress -Activity 'Scheduled Tasks: Getting share session information' -Status 'Done' -Completed
        }
        Write-Verbose -Message "Scheduled Tasks: Closing runspace pool"
        $rp.Close()
        $rp.Dispose()
    }
}