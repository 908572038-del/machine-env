#pragma once

#include <cstdint>
#include <cstdio>
#include <cstddef>
#include <cstdlib>
#include <iomanip>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <variant>
#include <vector>
#include <utility>

namespace machine_env {

struct Json {
    using Array = std::vector<Json>;
    using Object = std::map<std::string, Json>;
    using Value = std::variant<std::nullptr_t, bool, std::int64_t, double,
                               std::string, Array, Object>;

    Value value = nullptr;

    Json() = default;
    Json(std::nullptr_t) : value(nullptr) {}
    Json(bool v) : value(v) {}
    Json(int v) : value(static_cast<std::int64_t>(v)) {}
    Json(unsigned v) : value(static_cast<std::int64_t>(v)) {}
    Json(std::int64_t v) : value(v) {}
    Json(double v) : value(v) {}
    Json(const char* v) : value(std::string(v)) {}
    Json(std::string v) : value(std::move(v)) {}
    Json(Array v) : value(std::move(v)) {}
    Json(Object v) : value(std::move(v)) {}

    static Json object() { return Object{}; }
    static Json array() { return Array{}; }

    bool is_object() const { return std::holds_alternative<Object>(value); }
    bool is_array() const { return std::holds_alternative<Array>(value); }
    bool is_string() const { return std::holds_alternative<std::string>(value); }
    bool is_bool() const { return std::holds_alternative<bool>(value); }
    bool is_number() const {
        return std::holds_alternative<std::int64_t>(value) ||
               std::holds_alternative<double>(value);
    }

    Object& as_object() {
        if (!is_object()) throw std::runtime_error("expected a JSON object");
        return std::get<Object>(value);
    }
    const Object& as_object() const {
        if (!is_object()) throw std::runtime_error("expected a JSON object");
        return std::get<Object>(value);
    }
    Array& as_array() {
        if (!is_array()) throw std::runtime_error("expected a JSON array");
        return std::get<Array>(value);
    }
    const Array& as_array() const {
        if (!is_array()) throw std::runtime_error("expected a JSON array");
        return std::get<Array>(value);
    }
    const std::string& as_string() const {
        if (!is_string()) throw std::runtime_error("expected a JSON string");
        return std::get<std::string>(value);
    }
    bool as_bool() const {
        if (!is_bool()) throw std::runtime_error("expected a JSON boolean");
        return std::get<bool>(value);
    }
    std::int64_t as_integer() const {
        if (std::holds_alternative<std::int64_t>(value))
            return std::get<std::int64_t>(value);
        if (std::holds_alternative<double>(value))
            return static_cast<std::int64_t>(std::get<double>(value));
        throw std::runtime_error("expected a JSON number");
    }

    bool contains(const std::string& key) const {
        return is_object() && as_object().find(key) != as_object().end();
    }
    const Json& at(const std::string& key) const {
        auto it = as_object().find(key);
        if (it == as_object().end())
            throw std::runtime_error("missing JSON key: " + key);
        return it->second;
    }
    Json& operator[](const std::string& key) {
        if (!is_object()) value = Object{};
        return std::get<Object>(value)[key];
    }
    const Json& get(const std::string& key) const {
        static const Json null_value;
        if (!is_object()) return null_value;
        auto it = as_object().find(key);
        return it == as_object().end() ? null_value : it->second;
    }
};

class JsonParser {
public:
    explicit JsonParser(const std::string& source) : source_(source) {}

    Json parse() {
        skip_space();
        Json result = parse_value();
        skip_space();
        if (position_ != source_.size()) fail("trailing data");
        return result;
    }

private:
    const std::string& source_;
    std::size_t position_ = 0;

    [[noreturn]] void fail(const std::string& message) const {
        throw std::runtime_error("JSON parse error at byte " +
                                 std::to_string(position_) + ": " + message);
    }

    void skip_space() {
        while (position_ < source_.size() &&
               (source_[position_] == ' ' || source_[position_] == '\t' ||
                source_[position_] == '\r' || source_[position_] == '\n'))
            ++position_;
    }

    bool consume(char ch) {
        if (position_ < source_.size() && source_[position_] == ch) {
            ++position_;
            return true;
        }
        return false;
    }

    void expect(char ch) {
        if (!consume(ch)) fail(std::string("expected '") + ch + "'");
    }

    Json parse_value() {
        if (position_ >= source_.size()) fail("unexpected end of input");
        switch (source_[position_]) {
        case 'n': parse_literal("null"); return nullptr;
        case 't': parse_literal("true"); return true;
        case 'f': parse_literal("false"); return false;
        case '"': return parse_string();
        case '[': return parse_array();
        case '{': return parse_object();
        default:
            if (source_[position_] == '-' ||
                (source_[position_] >= '0' && source_[position_] <= '9'))
                return parse_number();
            fail("unexpected token");
        }
    }

    void parse_literal(const char* literal) {
        while (*literal) {
            if (position_ >= source_.size() || source_[position_] != *literal)
                fail("invalid literal");
            ++position_;
            ++literal;
        }
    }

    static void append_utf8(std::string& out, std::uint32_t cp) {
        if (cp <= 0x7f) {
            out.push_back(static_cast<char>(cp));
        } else if (cp <= 0x7ff) {
            out.push_back(static_cast<char>(0xc0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
        } else if (cp <= 0xffff) {
            out.push_back(static_cast<char>(0xe0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
        } else if (cp <= 0x10ffff) {
            out.push_back(static_cast<char>(0xf0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
        } else {
            throw std::runtime_error("invalid Unicode code point");
        }
    }

    unsigned parse_hex4() {
        if (position_ + 4 > source_.size()) fail("incomplete Unicode escape");
        unsigned result = 0;
        for (int i = 0; i < 4; ++i) {
            const char ch = source_[position_++];
            result <<= 4;
            if (ch >= '0' && ch <= '9') result |= digit_value(ch - '0');
            else if (ch >= 'a' && ch <= 'f') result |= digit_value(ch - 'a' + 10);
            else if (ch >= 'A' && ch <= 'F') result |= digit_value(ch - 'A' + 10);
            else fail("invalid Unicode escape");
        }
        return result;
    }

    static unsigned digit_value(char value) {
        return static_cast<unsigned char>(value);
    }

    std::string parse_string() {
        expect('"');
        std::string result;
        while (position_ < source_.size()) {
            const unsigned char ch =
                static_cast<unsigned char>(source_[position_++]);
            if (ch == '"') return result;
            if (ch < 0x20) fail("unescaped control character");
            if (ch != '\\') {
                result.push_back(static_cast<char>(ch));
                continue;
            }
            if (position_ >= source_.size()) fail("incomplete escape");
            switch (source_[position_++]) {
            case '"': result.push_back('"'); break;
            case '\\': result.push_back('\\'); break;
            case '/': result.push_back('/'); break;
            case 'b': result.push_back('\b'); break;
            case 'f': result.push_back('\f'); break;
            case 'n': result.push_back('\n'); break;
            case 'r': result.push_back('\r'); break;
            case 't': result.push_back('\t'); break;
            case 'u': {
                unsigned cp = parse_hex4();
                if (cp >= 0xd800 && cp <= 0xdbff) {
                    if (position_ + 2 > source_.size() ||
                        source_[position_] != '\\' ||
                        source_[position_ + 1] != 'u')
                        fail("missing low surrogate");
                    position_ += 2;
                    const unsigned low = parse_hex4();
                    if (low < 0xdc00 || low > 0xdfff)
                        fail("invalid low surrogate");
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                } else if (cp >= 0xdc00 && cp <= 0xdfff) {
                    fail("unexpected low surrogate");
                }
                append_utf8(result, cp);
                break;
            }
            default: fail("invalid escape");
            }
        }
        fail("unterminated string");
    }

    Json parse_array() {
        expect('[');
        skip_space();
        Json::Array result;
        if (consume(']')) return result;
        while (true) {
            skip_space();
            result.push_back(parse_value());
            skip_space();
            if (consume(']')) return result;
            expect(',');
        }
    }

    Json parse_object() {
        expect('{');
        skip_space();
        Json::Object result;
        if (consume('}')) return result;
        while (true) {
            skip_space();
            if (position_ >= source_.size() || source_[position_] != '"')
                fail("object key must be a string");
            std::string key = parse_string();
            skip_space();
            expect(':');
            skip_space();
            if (!result.emplace(std::move(key), parse_value()).second)
                fail("duplicate object key");
            skip_space();
            if (consume('}')) return result;
            expect(',');
        }
    }

    Json parse_number() {
        const std::size_t start = position_;
        consume('-');
        if (consume('0')) {
            if (position_ < source_.size() && source_[position_] >= '0' &&
                source_[position_] <= '9')
                fail("leading zero");
        } else {
            parse_digits();
        }
        bool fractional = false;
        if (consume('.')) {
            fractional = true;
            parse_digits();
        }
        if (consume('e') || consume('E')) {
            fractional = true;
            if (!consume('+')) consume('-');
            parse_digits();
        }
        const std::string token = source_.substr(start, position_ - start);
        try {
            if (!fractional) {
                std::size_t used = 0;
                const auto integer = std::stoll(token, &used);
                if (used == token.size()) return static_cast<std::int64_t>(integer);
            }
            std::size_t used = 0;
            const double number = std::stod(token, &used);
            if (used != token.size()) fail("invalid number");
            return number;
        } catch (const std::exception&) {
            fail("invalid number");
        }
    }

    void parse_digits() {
        const std::size_t start = position_;
        while (position_ < source_.size() && source_[position_] >= '0' &&
               source_[position_] <= '9')
            ++position_;
        if (position_ == start) fail("expected digit");
    }
};

inline void json_quote(const std::string& value, std::string& out) {
    static const char hex[] = "0123456789abcdef";
    out.push_back('"');
    for (unsigned char ch : value) {
        switch (ch) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (ch < 0x20) {
                out += "\\u00";
                out.push_back(hex[ch >> 4]);
                out.push_back(hex[ch & 0xf]);
            } else {
                out.push_back(static_cast<char>(ch));
            }
        }
    }
    out.push_back('"');
}

inline void serialize_json(const Json& json, std::string& out) {
    if (std::holds_alternative<std::nullptr_t>(json.value)) {
        out += "null";
    } else if (std::holds_alternative<bool>(json.value)) {
        out += std::get<bool>(json.value) ? "true" : "false";
    } else if (std::holds_alternative<std::int64_t>(json.value)) {
        out += std::to_string(std::get<std::int64_t>(json.value));
    } else if (std::holds_alternative<double>(json.value)) {
        std::ostringstream stream;
        stream << std::setprecision(17) << std::get<double>(json.value);
        out += stream.str();
    } else if (std::holds_alternative<std::string>(json.value)) {
        json_quote(std::get<std::string>(json.value), out);
    } else if (json.is_array()) {
        out.push_back('[');
        bool first = true;
        for (const auto& item : json.as_array()) {
            if (!first) out.push_back(',');
            serialize_json(item, out);
            first = false;
        }
        out.push_back(']');
    } else {
        out.push_back('{');
        bool first = true;
        for (const auto& item : json.as_object()) {
            if (!first) out.push_back(',');
            json_quote(item.first, out);
            out.push_back(':');
            serialize_json(item.second, out);
            first = false;
        }
        out.push_back('}');
    }
}

inline std::string dump_json(const Json& json) {
    std::string result;
    serialize_json(json, result);
    return result;
}

inline Json parse_json(const std::string& source) {
    return JsonParser(source).parse();
}

}  // namespace machine_env
