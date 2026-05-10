# File I/O — đọc và ghi file

# ── Ghi file ──
println("=== Ghi file ===")

f = open("output.txt", "w")
writeln(f, "Xin chào từ MiniJulia!")
writeln(f, "Dòng thứ hai")
writeln(f, "Pi xấp xỉ: " * string(3.14159))

# Ghi nhiều dòng với vòng lặp
i = 1
while i <= 5
    writeln(f, "Dòng " * string(i) * ": số bình phương = " * string(i * i))
    i = i + 1
end
close(f)
println("Đã ghi file output.txt")

# ── Đọc file ──
println("")
println("=== Đọc file ===")

g = open("output.txt", "r")
line_num = 1
line = read(g)
while !isnothing(line)
    println(string(line_num) * ": " * line)
    line_num = line_num + 1
    line = read(g)
end
close(g)

# ── Ghi file CSV ──
println("")
println("=== Ghi CSV ===")

csv = open("data.csv", "w")
writeln(csv, "tên,điểm,xếp loại")

students = ["An", "Bình", "Chi", "Dũng", "Em"]
scores   = [85, 92, 78, 95, 88]
i = 1
while i <= length(students)
    score = scores[i]
    grade = "C"
    if score >= 90
        grade = "A"
    elseif score >= 80
        grade = "B"
    end
    writeln(csv, students[i] * "," * string(score) * "," * grade)
    i = i + 1
end
close(csv)
println("Đã ghi data.csv")

# Đọc lại CSV
println("")
println("=== Đọc CSV ===")
h = open("data.csv", "r")
header = read(h)
println("Header: " * header)
row = read(h)
while !isnothing(row)
    println("  " * row)
    row = read(h)
end
close(h)

# Dọn dẹp
println("")
println("Done!")
