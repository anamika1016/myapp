package = Axlsx::Package.new
workbook = package.workbook

workbook.add_worksheet(name: "Employees") do |sheet|
  sheet.add_row [ "Name", "Email", "Employee Code", "L1 Code", "L1 Name", "L2 Code", "L2 Name", "OBS Code 1", "OBS Code 2", "OBS Code 3", "OBS Code 4", "Post", "Location", "Department" ]
  @employee_details.each do |emp|
    sheet.add_row [
      emp.employee_name,
      emp.employee_email,
      emp.employee_code,
      emp.l1_code,
      emp.l1_employer_name,
      emp.l2_code,
      emp.l2_employer_name,
      emp.obs_code1,
      emp.obs_code2,
      emp.obs_code3,
      emp.obs_code4,
      emp.post,
      emp.location,
      emp.department
    ]
  end
end

# Set response headers and render file
tempfile = Tempfile.new([ "employee_details", ".xlsx" ])
package.serialize(tempfile.path)

send_file tempfile.path, filename: "employee_details.xlsx", type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
