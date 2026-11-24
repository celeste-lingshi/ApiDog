package apidog

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <string.h>

static OSStatus apidog_key(unsigned char *out) {
	const void *keys[] = {kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData};
	const void *values[] = {kSecClassGenericPassword, CFSTR("com.celeste-lingshi.apidog.workspace"),
		CFSTR("工作区加密密钥"), kCFBooleanTrue};
	CFDictionaryRef query = CFDictionaryCreate(NULL, keys, values, 4,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFTypeRef result = NULL;
	OSStatus status = SecItemCopyMatching(query, &result);
	CFRelease(query);
	if (status == errSecSuccess) {
		if (result && CFGetTypeID(result) == CFDataGetTypeID() && CFDataGetLength(result) == 32)
			memcpy(out, CFDataGetBytePtr(result), 32);
		else status = errSecDecode;
	}
	if (result) CFRelease(result);
	return status;
}
*/
import "C"
import "fmt"

func ReadLegacyKey() ([]byte, error) {
	key := make([]byte, 32)
	status := C.apidog_key((*C.uchar)(&key[0]))
	if status != 0 {
		return nil, fmt.Errorf("无法访问 ApiDog 的旧钥匙串密钥（系统状态 %d）。", status)
	}
	return key, nil
}
