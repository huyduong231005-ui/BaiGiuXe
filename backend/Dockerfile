# REST API Dart cho Render (runtime docker): biên dịch thành 1 file chạy, image cuối chỉ có file đó + thư viện tối thiểu.
FROM dart:3.13 AS build
# Dữ liệu múi giờ: phí qua đêm, ngày doanh thu tính theo TZ=Asia/Ho_Chi_Minh
RUN apt-get update && apt-get install -y --no-install-recommends tzdata && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o bin/server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=build /app/bin/server /app/bin/server
COPY --from=build /app/public /app/public
WORKDIR /app
ENV TZ=Asia/Ho_Chi_Minh
EXPOSE 3000
CMD ["/app/bin/server"]
