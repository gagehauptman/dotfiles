percent=$(acpi | grep "Battery 0" | grep -o "[0-9]*%")
echo ${percent/%?/}
