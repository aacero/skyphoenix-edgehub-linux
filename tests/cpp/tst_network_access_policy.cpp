#include <QtTest>
#include <QTemporaryFile>
#include <QQmlComponent>
#include <QQmlEngine>

#include "hermetic.h"
#include "network_access_policy.h"

XENEON_REQUIRE_HERMETIC_ENV();

class FakeNetworkReply final : public QNetworkReply {
public:
    explicit FakeNetworkReply(
        const QNetworkRequest& request, QObject* parent = nullptr)
        : QNetworkReply(parent) {
        setOperation(QNetworkAccessManager::GetOperation);
        setRequest(request);
        setUrl(request.url());
        open(QIODevice::ReadOnly);
    }

    void publishMetadata(int status) {
        setAttribute(QNetworkRequest::HttpStatusCodeAttribute, status);
        setRawHeader("Content-Type", "application/json");
        emit metaDataChanged();
    }

    void push(const QByteArray& bytes) {
        pending_.append(bytes);
        emit readyRead();
    }

    void reportProgress(qint64 received, qint64 total) {
        emit downloadProgress(received, total);
    }

    void succeed() {
        setFinished(true);
        emit finished();
    }

    void finishWithError(NetworkError code, const QString& reason) {
        setError(code, reason);
        setFinished(true);
        emit finished();
    }

    void fail(NetworkError code, const QString& reason) {
        setError(code, reason);
        emit errorOccurred(code);
        setFinished(true);
        emit finished();
    }

    void abort() override {
        aborted = true;
        if (quietAbort)
            return;
        if (!isFinished()) {
            setError(OperationCanceledError, QStringLiteral("fake aborted"));
            emit errorOccurred(OperationCanceledError);
            setFinished(true);
            emit finished();
        }
    }

    bool aborted = false;
    bool quietAbort = false;

protected:
    qint64 readData(char* data, qint64 maxSize) override {
        if (pending_.isEmpty()) return isFinished() ? -1 : 0;
        const qint64 count = std::min<qint64>(pending_.size(), maxSize);
        std::memcpy(data, pending_.constData(), static_cast<std::size_t>(count));
        pending_.remove(0, static_cast<qsizetype>(count));
        return count;
    }

private:
    QByteArray pending_;
};

class NetworkAccessPolicyTest final : public QObject {
    Q_OBJECT

private slots:
    void qmlNetworkManagerAllowsSameOriginRedirectsOnly() {
        QObject owner;
        XeneonNetworkAccessManagerFactory factory;
        QNetworkAccessManager* manager = factory.create(&owner);

        QVERIFY(manager != nullptr);
        QVERIFY(dynamic_cast<XeneonNetworkAccessManager*>(manager) != nullptr);
        QCOMPARE(manager->parent(), &owner);
        QCOMPARE(manager->redirectPolicy(), QNetworkRequest::SameOriginRedirectPolicy);
    }

    void httpsRequestsDisableTheBrokenQtHttp2CleanupPath() {
        QNetworkRequest source(
            QUrl(QStringLiteral("https://api.github.com/repos/example/releases")));
        source.setRawHeader("Accept", "application/json");
        source.setRawHeader(
            XeneonNetworkAccessManager::kResponseLimitHeader, "1048576");
        source.setAttribute(QNetworkRequest::Http2AllowedAttribute, true);

        const QNetworkRequest prepared =
            XeneonNetworkAccessManager::transportRequest(source);

        QCOMPARE(prepared.url(), source.url());
        QCOMPARE(prepared.rawHeader("Accept"), QByteArray("application/json"));
        QVERIFY(!prepared.hasRawHeader(
            XeneonNetworkAccessManager::kResponseLimitHeader));
        QCOMPARE(prepared.rawHeader("Accept-Encoding"), QByteArray("identity"));
        QCOMPARE(prepared.decompressedSafetyCheckThreshold(), 1024);
        QCOMPARE(
            prepared.attribute(QNetworkRequest::Http2AllowedAttribute).toBool(),
            false);
        QCOMPARE(
            source.attribute(QNetworkRequest::Http2AllowedAttribute).toBool(),
            true);
    }

    void nonTlsRequestsKeepTheirOriginalTransportPolicy() {
        QNetworkRequest source(QUrl(QStringLiteral("file:///tmp/widget-value.json")));
        QVERIFY(!source.attribute(QNetworkRequest::Http2AllowedAttribute).isValid());

        const QNetworkRequest prepared =
            XeneonNetworkAccessManager::transportRequest(source);

        QCOMPARE(prepared.url(), source.url());
        QVERIFY(!prepared.attribute(QNetworkRequest::Http2AllowedAttribute).isValid());
    }

    void responseLimitIsParsedClampedAndNeverSentToTheServer() {
        QNetworkRequest request(QUrl(QStringLiteral("https://example.test/value")));
        QCOMPARE(
            XeneonNetworkAccessManager::responseByteLimit(request),
            XeneonNetworkAccessManager::kMaximumResponseBytes);

        request.setRawHeader(
            XeneonNetworkAccessManager::kResponseLimitHeader, "1024");
        QCOMPARE(XeneonNetworkAccessManager::responseByteLimit(request), 1024);

        request.setRawHeader(
            XeneonNetworkAccessManager::kResponseLimitHeader, "1");
        QCOMPARE(
            XeneonNetworkAccessManager::responseByteLimit(request),
            XeneonNetworkAccessManager::kMinimumResponseBytes);

        request.setRawHeader(
            XeneonNetworkAccessManager::kResponseLimitHeader, "999999999");
        QCOMPARE(
            XeneonNetworkAccessManager::responseByteLimit(request),
            XeneonNetworkAccessManager::kMaximumResponseBytes);

        request.setRawHeader(
            XeneonNetworkAccessManager::kResponseLimitHeader, "not-a-number");
        QCOMPARE(
            XeneonNetworkAccessManager::responseByteLimit(request),
            XeneonNetworkAccessManager::kMaximumResponseBytes);
    }

    void boundedReplyStreamsNormalMetadataAndBody() {
        QNetworkRequest request(QUrl(QStringLiteral("https://example.test/value")));
        auto* upstream = new FakeNetworkReply(request, this);
        XeneonBoundedNetworkReply reply(upstream, 16);
        QSignalSpy metadata(&reply, &QNetworkReply::metaDataChanged);
        QSignalSpy ready(&reply, &QIODevice::readyRead);
        QSignalSpy progress(&reply, &QNetworkReply::downloadProgress);
        QSignalSpy finished(&reply, &QNetworkReply::finished);

        upstream->publishMetadata(203);
        QCOMPARE(metadata.count(), 1);
        QCOMPARE(
            reply.attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt(),
            203);
        QCOMPARE(reply.rawHeader("Content-Type"), QByteArray("application/json"));

        upstream->push("abcd");
        QCOMPARE(ready.count(), 1);
        QCOMPARE(reply.bytesAvailable(), qint64(4));
        upstream->reportProgress(999, 12);
        QCOMPARE(progress.count(), 1);
        QCOMPARE(progress.at(0).at(0).toLongLong(), qint64(4));
        QCOMPARE(progress.at(0).at(1).toLongLong(), qint64(12));
        QCOMPARE(reply.readAll(), QByteArray("abcd"));
        upstream->succeed();
        QCOMPARE(finished.count(), 1);
        QVERIFY(reply.isFinished());
        QCOMPARE(reply.error(), QNetworkReply::NoError);
    }

    void boundedReplyExposesOneSentinelByteThenAbortsUpstream() {
        QNetworkRequest request(QUrl(QStringLiteral("https://example.test/value")));
        auto* upstream = new FakeNetworkReply(request, this);
        XeneonBoundedNetworkReply reply(upstream, 4);
        QSignalSpy errors(&reply, &QNetworkReply::errorOccurred);
        QSignalSpy finished(&reply, &QNetworkReply::finished);

        upstream->push("abcdefgh");

        QCOMPARE(reply.readAll(), QByteArray("abcde"));
        QVERIFY(upstream->aborted);
        QVERIFY(reply.isFinished());
        QCOMPARE(reply.error(), QNetworkReply::ContentAccessDenied);
        QCOMPARE(errors.count(), 1);
        QCOMPARE(finished.count(), 1);
        QVERIFY(reply.property("_xeneonResponseLimitExceeded").toBool());
    }

    void boundedReplyPropagatesUpstreamFailure() {
        QNetworkRequest request(QUrl(QStringLiteral("https://example.test/value")));
        auto* upstream = new FakeNetworkReply(request, this);
        XeneonBoundedNetworkReply reply(upstream, 16);
        QSignalSpy errors(&reply, &QNetworkReply::errorOccurred);

        upstream->fail(
            QNetworkReply::HostNotFoundError, QStringLiteral("host missing"));

        QVERIFY(reply.isFinished());
        QCOMPARE(reply.error(), QNetworkReply::HostNotFoundError);
        QCOMPARE(errors.count(), 1);
        QCOMPARE(reply.errorString(), QStringLiteral("host missing"));
    }

    void boundedReplyFindsAnErrorThatArrivesOnlyWithFinished() {
        QNetworkRequest request(QUrl(QStringLiteral("https://example.test/value")));
        auto* upstream = new FakeNetworkReply(request, this);
        XeneonBoundedNetworkReply reply(upstream, 16);
        QSignalSpy errors(&reply, &QNetworkReply::errorOccurred);

        upstream->finishWithError(
            QNetworkReply::TimeoutError, QStringLiteral("deadline reached"));

        QVERIFY(reply.isFinished());
        QCOMPARE(reply.error(), QNetworkReply::TimeoutError);
        QCOMPARE(reply.errorString(), QStringLiteral("deadline reached"));
        QCOMPARE(errors.count(), 1);
    }

    void callerAbortSuppliesAnErrorWhenTransportIsSilent() {
        QNetworkRequest request(QUrl(QStringLiteral("https://example.test/value")));
        auto* upstream = new FakeNetworkReply(request, this);
        upstream->quietAbort = true;
        XeneonBoundedNetworkReply reply(upstream, 16);
        QSignalSpy errors(&reply, &QNetworkReply::errorOccurred);
        QSignalSpy finished(&reply, &QNetworkReply::finished);

        reply.abort();

        QVERIFY(upstream->aborted);
        QVERIFY(reply.isFinished());
        QCOMPARE(reply.error(), QNetworkReply::OperationCanceledError);
        QCOMPARE(reply.errorString(), QStringLiteral("request aborted"));
        QCOMPARE(errors.count(), 1);
        QCOMPARE(finished.count(), 1);
    }

    void callerAbortPropagatesOnce() {
        QNetworkRequest request(QUrl(QStringLiteral("https://example.test/value")));
        auto* upstream = new FakeNetworkReply(request, this);
        XeneonBoundedNetworkReply reply(upstream, 16);
        QSignalSpy finished(&reply, &QNetworkReply::finished);

        reply.abort();
        reply.abort();

        QVERIFY(upstream->aborted);
        QVERIFY(reply.isFinished());
        QCOMPARE(reply.error(), QNetworkReply::OperationCanceledError);
        QCOMPARE(finished.count(), 1);
    }

    void realManagerRequestIsWrappedAndBounded() {
        QTemporaryFile source;
        QVERIFY(source.open());
        QCOMPARE(source.write("local response"), qint64(14));
        QVERIFY(source.flush());

        XeneonNetworkAccessManager manager;
        QNetworkRequest request(QUrl::fromLocalFile(source.fileName()));
        request.setRawHeader(
            XeneonNetworkAccessManager::kResponseLimitHeader, "1024");
        QNetworkReply* reply = manager.get(request);
        QVERIFY(reply != nullptr);
        QVERIFY(dynamic_cast<XeneonBoundedNetworkReply*>(reply) != nullptr);
        QSignalSpy finished(reply, &QNetworkReply::finished);
        if (!reply->isFinished())
            QVERIFY(finished.wait(1000));
        QCOMPARE(reply->error(), QNetworkReply::NoError);
        QCOMPARE(reply->readAll(), QByteArray("local response"));
        delete reply;
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        QCOMPARE(manager.findChildren<QNetworkReply*>().count(), 0);
    }

    void qmlXmlHttpRequestCleansUpReplies() {
        qputenv("QML_XHR_ALLOW_FILE_READ", "1");
        QTemporaryFile source;
        QVERIFY(source.open());
        QCOMPARE(source.write("qml response"), qint64(12));
        QVERIFY(source.flush());

        QQmlEngine engine;
        XeneonNetworkAccessManagerFactory factory;
        engine.setNetworkAccessManagerFactory(&factory);

        QQmlComponent component(&engine);
        component.setData(
            QByteArray("import QtQuick\n"
                       "QtObject {\n"
                       "    property bool done: false\n"
                       "    property string text: \"\"\n"
                       "    function run(url) {\n"
                       "        var xhr = new XMLHttpRequest()\n"
                       "        xhr.open('GET', url)\n"
                       "        xhr.onreadystatechange = function() {\n"
                       "            if (xhr.readyState === XMLHttpRequest.DONE) {\n"
                       "                text = xhr.responseText\n"
                       "                done = true\n"
                       "            }\n"
                       "        }\n"
                       "        xhr.send()\n"
                       "    }\n"
                       "}"), QUrl());
        QScopedPointer<QObject> obj(component.create());
        QVERIFY(obj != nullptr);

        QMetaObject::invokeMethod(obj.data(), "run", Q_ARG(QVariant, QUrl::fromLocalFile(source.fileName()).toString()));
        QTRY_VERIFY_WITH_TIMEOUT(obj->property("done").toBool(), 2000);
        QCOMPARE(obj->property("text").toString(), QStringLiteral("qml response"));

        auto* manager = engine.networkAccessManager();
        QVERIFY(manager != nullptr);
        engine.collectGarbage();
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        QCOMPARE(manager->findChildren<QNetworkReply*>().count(), 0);
    }

    void repeatedRequestsDoNotAccumulateChildrenInManager() {
        QTemporaryFile source;
        QVERIFY(source.open());
        QCOMPARE(source.write("payload"), qint64(7));
        QVERIFY(source.flush());

        XeneonNetworkAccessManager manager;
        const QUrl url = QUrl::fromLocalFile(source.fileName());
        for (int i = 0; i < 25; ++i) {
            QNetworkRequest request(url);
            QNetworkReply* reply = manager.get(request);
            QVERIFY(reply != nullptr);
            QSignalSpy finished(reply, &QNetworkReply::finished);
            if (!reply->isFinished())
                QVERIFY(finished.wait(1000));
            QCOMPARE(reply->readAll(), QByteArray("payload"));
            delete reply;
        }
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        QCOMPARE(manager.findChildren<QNetworkReply*>().count(), 0);
    }
};

QTEST_MAIN(NetworkAccessPolicyTest)
#include "tst_network_access_policy.moc"
