$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger | Format-List *
